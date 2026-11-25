package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// Everything for the chat that filed a report (spec 014 FR-1440 to FR-1451; Toni, 2026-11-25:
// "Everything for that chat", "5 MB, screenshots included"). Choices: plan.md D7.

// DefaultPartDeadline is how long the relay waits for a machine's part (FR-1443).
const DefaultPartDeadline = 10 * time.Second

const (
	// chatLookBack is how far back other sessions of the same chat are looked for (FR-1441).
	chatLookBack = 24 * time.Hour
	// sizeMargin leaves room for sealing (the KEM's encapsulation, the tag, the magic).
	sizeMargin = 4 << 10
)

// pageName is the shape of a page name Latchkey gives (spec 005 FR-444; OwnPages.newName).
var pageName = regexp.MustCompile(`^p[abcdefghjkmnpqrstuvwxyz23456789]{4}$`)

// pageInAnswer finds the page names an answer gives ("page p4k2").
var pageInAnswer = regexp.MustCompile(`\bpage (p[abcdefghjkmnpqrstuvwxyz23456789]{4})\b`)

// codeLike is typed text with the shape of a verification code: 4 to 8 digits (FR-1448); only
// under typedKeys, so a year or a port given as an argument isn't taken for one.
var (
	codeLike  = regexp.MustCompile(`^[0-9]{4,8}$`)
	typedKeys = map[string]bool{"text": true, "value": true, "keys": true}
)

// secretKeys are argument names whose value is a secret wherever they appear (FR-1448), and
// secretParts are parts of a name that make it one (api_key, access_token, client_secret);
// security review 2026-11-25.
var (
	secretKeys  = map[string]bool{"code": true, "password": true, "passcode": true, "otp": true, "pin": true, "passphrase": true}
	secretParts = []string{"password", "passwd", "token", "secret", "apikey", "api_key", "authorization", "cookie", "credential", "private_key"}
	// bearerLike finds a credential written into text (a header in a shell command).
	bearerLike = regexp.MustCompile(`(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{16,}`)
	// secretInText finds secrets in any text of the report, answers included (cat .env, a
	// credentials file, a header in a command): the value after a secret's name, a credential
	// after its scheme, cloud keys, and private key blocks (security review 2026-11-25).
	secretInText = []*regexp.Regexp{
		regexp.MustCompile(`(?i)((?:password|passwd|pwd|passphrase|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|authorization|cookie|session[_-]?id)["']?\s*[:=]\s*["']?)([^\s"'&,;<>]{4,})`),
		regexp.MustCompile(`(?i)(\b(?:bearer|basic)\s+)([A-Za-z0-9._~+/=-]{12,})`),
		regexp.MustCompile(`()\b((?:AKIA|ASIA)[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abpr]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,})\b`),
		regexp.MustCompile(`()(-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----)`),
	}
)

// blankSecrets replaces the secrets secretInText finds in s, keeping the names before them.
func blankSecrets(s string) string {
	for _, re := range secretInText {
		s = re.ReplaceAllString(s, "${1}(blanked)")
	}
	return s
}

func secretKey(k string) bool {
	if secretKeys[k] {
		return true
	}
	for _, p := range secretParts {
		if strings.Contains(k, p) {
			return true
		}
	}
	return false
}

// chat is what the relay's trace holds of one chat.
type chat struct {
	calls    []trace.Line
	events   []trace.Line
	sessions int
	how      string
	pages    []string
	from, to time.Time
}

// maxChatCalls bounds how many of the chat's calls a report holds (the newest).
const maxChatCalls = 500

// chatOf reads the account's trace for the chat the request came in on (FR-1441). The first
// pass keeps no answers, only what joins sessions; the second reads the chat's lines in full, so
// a report never holds the account's whole day in memory (security review 2026-11-25).
func (s *Server) chatOf(userID, session string, now time.Time) chat {
	c := chat{from: now, to: now, how: "session"}
	if s.opts.Traces == nil {
		return c
	}
	if session == "" {
		// A client without sessions: its calls can't be told from other chats', so none go in.
		c.how = "none: this Claude app gives no session, so the chat's calls can't be told from other chats'"
		return c
	}
	from := now.Add(-chatLookBack).UTC().Format(trace.DayFormat)
	to := now.UTC().Format(trace.DayFormat)
	at := func(l trace.Line) time.Time { t, _ := time.Parse(time.RFC3339Nano, l.Time); return t }
	type head struct {
		session string
		page    string   // the page its arguments name
		made    []string // the page names Latchkey's answer gives in its first line
		at      time.Time
	}
	var heads []head
	_, err := s.opts.Traces.Each(userID, from, to, func(l trace.Line) error {
		if l.Kind == trace.KindAction && l.Session != "" {
			heads = append(heads, head{session: l.Session, page: argPage(l.Arguments), made: answerPages(l.Result), at: at(l)})
		}
		return nil
	})
	if err != nil {
		s.opts.Logger.Warn("report: the trace couldn't be read", "user", userID, "err", err)
	}
	in := map[string]bool{session: true}
	pages := map[string]bool{}
	for range 8 { // the chat's own session, then each earlier one that worked in one of its pages
		for _, h := range heads {
			if in[h.session] {
				if h.page != "" {
					pages[h.page] = true
				}
				for _, p := range h.made {
					pages[p] = true
				}
			}
		}
		grew := false
		for _, h := range heads {
			if !in[h.session] && h.page != "" && pages[h.page] && now.Sub(h.at) <= chatLookBack {
				in[h.session], grew = true, true
			}
		}
		if !grew {
			break
		}
	}
	_, _ = s.opts.Traces.Each(userID, from, to, func(l trace.Line) error {
		if l.Kind == trace.KindAction && in[l.Session] {
			c.calls = append(c.calls, l)
			if len(c.calls) > maxChatCalls {
				c.calls = c.calls[1:]
			}
		}
		return nil
	})
	sort.SliceStable(c.calls, func(i, j int) bool { return at(c.calls[i]).Before(at(c.calls[j])) })
	if len(c.calls) > 0 {
		c.from = at(c.calls[0])
	}
	_, _ = s.opts.Traces.Each(userID, c.from.UTC().Format(trace.DayFormat), to, func(l trace.Line) error {
		if l.Kind == trace.KindEvent && !at(l).Before(c.from) {
			c.events = append(c.events, l)
		}
		return nil
	})
	c.sessions = len(in)
	for p := range pages {
		c.pages = append(c.pages, p)
	}
	sort.Strings(c.pages)
	return c
}

// argPage is the page a call's arguments name, "" for none.
func argPage(raw json.RawMessage) string {
	var args map[string]any
	if json.Unmarshal(raw, &args) == nil {
		if p, ok := args["page"].(string); ok {
			p = strings.ToLower(strings.TrimSpace(p))
			if pageName.MatchString(p) {
				return p
			}
		}
	}
	return ""
}

// answerPages are the page names in the first line of an answer's first text, which Latchkey
// writes ("Opened page pk4m2"); the rest is the page's, which could name any page.
func answerPages(raw json.RawMessage) []string {
	first, _, _ := strings.Cut(firstText(raw), "\n")
	var out []string
	for _, m := range pageInAnswer.FindAllStringSubmatch(first, -1) {
		out = append(out, m[1])
	}
	return out
}

// involved are the machines a report is about (FR-1412): each one Claude named or that answered
// one of the chat's calls; with none, every machine online now.
func involved(ms []machine, named []string, c chat) (out []machine, wasNamed []bool) {
	names := slices.Clone(named)
	for _, l := range c.calls {
		if l.Machine != "" {
			names = append(names, l.Machine)
		}
	}
	for _, m := range ms {
		for _, n := range names {
			if strings.EqualFold(m.Device.Name, n) {
				out = append(out, m)
				wasNamed = append(wasNamed, true)
				break
			}
		}
	}
	if len(out) > 0 {
		return out, wasNamed
	}
	for _, m := range ms {
		if m.Online {
			out = append(out, m)
			wasNamed = append(wasNamed, false)
		}
	}
	return out, wasNamed
}

// partResult is one machine's answer.
type partResult struct {
	answered bool
	note     string
	part     json.RawMessage
}

// askParts asks each involved machine for its part, all at once, each for at most the part
// deadline (FR-1443, Constitution II). The order of the answers is the order of ms.
func (s *Server) askParts(ctx context.Context, ms []machine, reportID string, c chat, now time.Time) []partResult {
	out := make([]partResult, len(ms))
	var callIDs []string
	for _, l := range c.calls {
		if l.CallID != "" {
			callIDs = append(callIDs, l.CallID)
		}
	}
	deadline := s.opts.PartDeadline
	if deadline <= 0 {
		deadline = DefaultPartDeadline
	}
	args, _ := json.Marshal(agentproto.ReportPartArgs{
		Report: reportID, Since: c.from.Add(-time.Minute).UnixMilli(), Until: now.UnixMilli(),
		CallIDs: callIDs, Pages: c.pages, MaxBytes: agentproto.MaxReportPartBytes,
	})
	var wg sync.WaitGroup
	for i, m := range ms {
		switch {
		case !m.Online:
			out[i].note = "offline"
			continue
		case !s.hub.AnswersReportPart(m.Device.ID):
			out[i].note = "its Latchkey version can't give its part"
			continue
		}
		wg.Add(1)
		go func(i int, deviceID string) {
			defer wg.Done()
			res, err := s.hub.CallWithID(ctx, deviceID, agentproto.NewCallID(), "", agentproto.ReportPartTool, args, deadline, nil)
			switch {
			case errors.Is(err, hub.ErrTimeout):
				out[i].note = fmt.Sprintf("didn't answer within %d seconds", int(deadline.Seconds()))
			case err != nil:
				out[i].note = "couldn't be asked: " + err.Error()
			default:
				text := firstText(res.Content)
				if res.IsError {
					out[i].note = "answered with an error: " + truncate(text, 2000)
					return
				}
				if !json.Valid([]byte(text)) {
					out[i].note = "answered with something that isn't a part"
					return
				}
				out[i].answered, out[i].part = true, json.RawMessage(text)
			}
		}(i, m.Device.ID)
	}
	wg.Wait()
	return out
}

func firstText(content json.RawMessage) string {
	var cs []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	_ = json.Unmarshal(content, &cs)
	for _, c := range cs {
		if c.Type == "text" {
			return c.Text
		}
	}
	return ""
}

// fullReport adds everything for the chat to r (format 3) and gives the plaintext of the report
// and of its small version (FR-1440 to FR-1451).
func (s *Server) fullReport(ctx context.Context, userID string, req *mcp.CallToolRequest,
	ms []machine, named []string, r reports.Report, now time.Time,
) (full, small []byte, err error) {
	c := s.chatOf(userID, sessionOf(req), now)
	inv, wasNamed := involved(ms, named, c)
	r.Format = 3
	r.Machines = nil
	labels := map[string]string{} // machine name, lower case → label
	for i, m := range inv {
		f := machineFacts(m, wasNamed[i])
		f.Label = fmt.Sprintf("machine %d", i+1)
		labels[strings.ToLower(m.Device.Name)] = f.Label
		r.Machines = append(r.Machines, f)
	}
	label := func(name string) string {
		if name == "" {
			return ""
		}
		if l, ok := labels[strings.ToLower(name)]; ok {
			return l
		}
		return "another machine"
	}
	r.Chat = &reports.Chat{Sessions: c.sessions, From: c.from.UTC(), To: now.UTC(), How: c.how}
	for _, l := range c.calls {
		r.Calls = append(r.Calls, reports.Call{
			Time: l.Time, Tool: l.Tool, Machine: label(l.Machine), CallID: l.CallID, Arguments: l.Arguments,
			Result: l.Result, IsError: l.IsError, DurationMS: l.DurationMS, Outcome: l.Outcome,
		})
	}
	if s.opts.Traces == nil {
		r.LeftOut = append(r.LeftOut, "the chat's calls: this relay keeps no trace")
	}
	for _, e := range c.events {
		r.RelayLog = append(r.RelayLog, e.Time+" EVENT "+e.Tool+": "+trimJSONString(e.Result))
	}
	for _, l := range s.opts.RelayLog.Lines(userID, c.from.Add(-time.Minute)) {
		r.RelayLog = append(r.RelayLog, l.Time.Format("2006-01-02T15:04:05.000Z")+" "+l.Text)
	}
	sort.Strings(r.RelayLog) // both start with the time
	for i, p := range s.askParts(ctx, inv, r.ID, c, now) {
		r.Parts = append(r.Parts, reports.Part{Machine: r.Machines[i].Label, Answered: p.answered, Note: p.note, Part: p.part})
	}

	secrets := secretsIn(r.Calls)
	names := map[string]string{}
	for _, m := range ms {
		names[m.Device.Name] = label(m.Device.Name)
	}
	if u, err := s.store.User(ctx, userID); err == nil && u.Email != "" {
		names[u.Email] = "(the account's email)"
	}
	if s.opts.PublicURL != nil && s.opts.PublicURL.Host != "" {
		names[s.opts.PublicURL.Host] = "(the relay)"
	}
	// What a machine said must go (FR-1448, FR-1449): values typed into its pages' password and
	// code fields, and its private names. Taken out of the part before anything is sealed.
	for i := range r.Parts {
		typed, private, cleaned := takePrivate(r.Parts[i].Part)
		secrets = append(secrets, typed...)
		for _, p := range private {
			names[p] = "(private)"
		}
		r.Parts[i].Part = cleaned
	}
	sort.Slice(secrets, func(i, j int) bool { return len(secrets[i]) > len(secrets[j]) })

	tree, err := toTree(r)
	if err != nil {
		return nil, nil, err
	}
	tree = scrubTree(tree, newScrubber(secrets, names))
	full, err = fit(tree.(map[string]any), reports.MaxSealed-sizeMargin)
	if err != nil {
		return nil, nil, err
	}
	small, err = smallVersion(tree.(map[string]any))
	return full, small, err
}

// takePrivate takes a part's "private" names and its pages' "secrets" out of it.
func takePrivate(part json.RawMessage) (secrets, private []string, cleaned json.RawMessage) {
	var p map[string]any
	if len(part) == 0 || json.Unmarshal(part, &p) != nil {
		return nil, nil, part
	}
	strs := func(v any) []string {
		var out []string
		for _, x := range asList(v) {
			if s, ok := x.(string); ok && len(strings.TrimSpace(s)) >= 3 {
				out = append(out, strings.TrimSpace(s))
			}
		}
		return out
	}
	private = strs(p["private"])
	delete(p, "private")
	secrets = strs(p["secrets"])
	delete(p, "secrets")
	for _, pg := range asList(p["pages"]) {
		if m, ok := pg.(map[string]any); ok {
			secrets = append(secrets, strs(m["secrets"])...)
			delete(m, "secrets")
		}
	}
	b, err := json.Marshal(p)
	if err != nil {
		return secrets, private, nil
	}
	return secrets, private, b
}

// trimJSONString is an event line's result, a JSON string, as plain text.
func trimJSONString(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return string(raw)
}

// secretsIn are the codes and passwords Claude passed to tools in the chat (FR-1448): any value
// of an argument named for one, and any argument with the shape of a code.
func secretsIn(calls []reports.Call) []string {
	seen := map[string]bool{}
	var out []string
	var walk func(key string, v any)
	walk = func(key string, v any) {
		switch x := v.(type) {
		case map[string]any:
			for k, vv := range x {
				walk(strings.ToLower(k), vv)
			}
		case []any:
			for _, vv := range x {
				walk(key, vv)
			}
		case bool, float64, nil:
		case string:
			for _, m := range bearerLike.FindAllString(x, -1) {
				if !seen[m] {
					seen[m] = true
					out = append(out, m)
				}
			}
			t := strings.TrimSpace(x)
			if len(t) >= 4 && (secretKey(key) || (typedKeys[key] && codeLike.MatchString(t))) && !seen[t] {
				seen[t] = true
				out = append(out, t)
			}
		}
	}
	for _, c := range calls {
		var args any
		if json.Unmarshal(c.Arguments, &args) == nil {
			walk("", args)
		}
	}
	sort.Slice(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}

func toTree(v any) (any, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	var t any
	err = json.Unmarshal(b, &t)
	return t, err
}

// scrubber replaces what a report must not hold (FR-1448, FR-1449): exact secrets Claude passed
// or a machine saw typed into a password or code field, secrets found in any text, and, ignoring
// case, machine names, the account's email, the relay's address and the private names a machine
// gave (its host and login name).
type scrubber struct {
	exact *strings.Replacer
	names []*regexp.Regexp
	label []string
}

func newScrubber(secrets []string, names map[string]string) *scrubber {
	var pairs []string
	for _, v := range secrets {
		pairs = append(pairs, v, "(blanked)")
	}
	keys := make([]string, 0, len(names))
	for k := range names {
		if len(k) >= 3 { // as long as a part's private names can be (takePrivate); whole words below
			keys = append(keys, k)
		}
	}
	sort.Slice(keys, func(i, j int) bool { return len(keys[i]) > len(keys[j]) }) // longest first
	sc := &scrubber{exact: strings.NewReplacer(pairs...)}
	for _, k := range keys {
		// Whole words only where the name begins or ends with one ("root" not in "rootfs").
		pat := regexp.QuoteMeta(k)
		if wordChar(k[0]) {
			pat = `\b` + pat
		}
		if wordChar(k[len(k)-1]) {
			pat += `\b`
		}
		sc.names = append(sc.names, regexp.MustCompile(`(?i)`+pat))
		sc.label = append(sc.label, names[k])
	}
	return sc
}

func wordChar(b byte) bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func (sc *scrubber) text(s string) string {
	s = blankSecrets(sc.exact.Replace(s))
	for i, re := range sc.names {
		s = re.ReplaceAllLiteralString(s, sc.label[i])
	}
	return s
}

// scrubTree scrubs every string of the report, except where a replaced byte would break what
// isn't text and holds nothing Claude passed (security review 2026-11-25: exemptions go by
// place, not by a key name an argument could also have): a picture's data in an answer or a
// machine's part, the report's own id and time, and the time and call id the relay gave a call.
func scrubTree(v any, sc *scrubber) any { return scrubAt(v, sc, "", "", nil) }

func scrubAt(v any, sc *scrubber, key, where string, parent map[string]any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, vv := range x {
			x[k] = scrubAt(vv, sc, k, where+"/"+k, x)
		}
		return x
	case []any:
		for i, vv := range x {
			x[i] = scrubAt(vv, sc, key, where+"/[]", parent)
		}
		return x
	case string:
		inContent := strings.HasPrefix(where, "/calls/[]/result/") || strings.HasPrefix(where, "/parts/[]/part/")
		image := inContent && key == "data" && parent != nil &&
			(parent["type"] == "image" || strings.HasSuffix(where, "/screenshot/data"))
		switch {
		case image, where == "/id", where == "/at", where == "/calls/[]/time", where == "/calls/[]/call_id",
			where == "/chat/from", where == "/chat/to":
			return x
		}
		return sc.text(x)
	}
	return v
}

// fit marshals the report, leaving out its oldest parts until it is at most limit bytes
// (FR-1450): answers of the oldest calls first (the newest call with a picture last), then the
// machines' traces, the oldest log lines, page sources, page records, screenshots.
func fit(t map[string]any, limit int) ([]byte, error) {
	base := asList(t["left_out"])
	counts := map[string]int{}
	// The oldest answers go in one pass, by their sizes, before the step by step below
	// (security review 2026-11-25: marshalling 5 MB once per call left out costs too much).
	if whole, err := json.Marshal(t); err == nil && len(whole) > limit {
		over := len(whole) - limit
		calls := asList(t["calls"])
		keep := -1
		for i := len(calls) - 1; i >= 0; i-- {
			if m, ok := calls[i].(map[string]any); ok && hasImage(m["result"]) {
				keep = i
				break
			}
		}
		for i, c := range calls {
			m, ok := c.(map[string]any)
			if over <= 0 || !ok || m["result"] == nil || i == keep {
				continue
			}
			b, _ := json.Marshal(m["result"])
			delete(m, "result")
			m["left_out"] = "size"
			over -= len(b)
			counts["the answer of an older call"]++
		}
	}
	for {
		if len(counts) > 0 {
			t["left_out"] = append(slices.Clone(base), summarize(counts)...)
		}
		b, err := json.Marshal(t)
		if err != nil || len(b) <= limit {
			return b, err
		}
		step, ok := trimOnce(t)
		if !ok {
			return nil, fmt.Errorf("the report is still %d bytes after leaving out everything that can be", len(b))
		}
		counts[step]++
	}
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

const sizeNote = " (size)"

func withoutSizeNotes(l []any) []any {
	var out []any
	for _, v := range l {
		if s, _ := v.(string); !strings.HasSuffix(s, sizeNote) {
			out = append(out, v)
		}
	}
	return out
}

func summarize(counts map[string]int) []any {
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]any, 0, len(keys))
	for _, k := range keys {
		out = append(out, fmt.Sprintf("%s ×%d%s", k, counts[k], sizeNote))
	}
	return out
}

func hasImage(v any) bool {
	for _, c := range asList(v) {
		if m, ok := c.(map[string]any); ok && m["type"] == "image" {
			return true
		}
	}
	return false
}

// trimOnce leaves out the next thing in FR-1450's order and names what it left out.
func trimOnce(t map[string]any) (string, bool) {
	calls := asList(t["calls"])
	keep := -1 // the newest call with a picture stays as long as anything else can go
	for i := len(calls) - 1; i >= 0; i-- {
		if m, ok := calls[i].(map[string]any); ok && hasImage(m["result"]) {
			keep = i
			break
		}
	}
	for i, c := range calls {
		if m, ok := c.(map[string]any); ok && m["result"] != nil && i != keep {
			delete(m, "result")
			m["left_out"] = "size"
			return "the answer of an older call", true
		}
	}
	parts := asList(t["parts"])
	each := func(f func(part map[string]any) (string, bool)) (string, bool) {
		for _, p := range parts {
			pm, _ := p.(map[string]any)
			part, _ := pm["part"].(map[string]any)
			if part == nil {
				continue
			}
			if s, ok := f(part); ok {
				return s, true
			}
		}
		return "", false
	}
	if s, ok := each(func(part map[string]any) (string, bool) {
		for _, c := range asList(part["calls"]) {
			if m, ok := c.(map[string]any); ok && m["result"] != nil {
				delete(m, "result")
				return "a machine's own copy of an answer", true
			}
		}
		return "", false
	}); ok {
		return s, true
	}
	if l := asList(t["relay_log"]); len(l) > 0 {
		t["relay_log"] = l[(len(l)+1)/2:]
		return "the older half of the relay's log", true
	}
	if s, ok := each(func(part map[string]any) (string, bool) {
		if l := asList(part["log"]); len(l) > 0 {
			part["log"] = l[(len(l)+1)/2:]
			return "the older half of a machine's log", true
		}
		return "", false
	}); ok {
		return s, true
	}
	pages := func(f func(page map[string]any) (string, bool)) (string, bool) {
		return each(func(part map[string]any) (string, bool) {
			for _, p := range asList(part["pages"]) {
				if pm, ok := p.(map[string]any); ok {
					if s, ok := f(pm); ok {
						return s, true
					}
				}
			}
			return "", false
		})
	}
	if s, ok := pages(func(p map[string]any) (string, bool) {
		if src, _ := p["source"].(string); len(src) > 1000 {
			p["source"] = src[:len(src)/2]
			p["source_cut"] = true
			return "the end of a page's source", true
		}
		return "", false
	}); ok {
		return s, true
	}
	if s, ok := pages(func(p map[string]any) (string, bool) {
		if l := asList(p["record"]); len(l) > 0 {
			p["record"] = l[(len(l)+1)/2:]
			return "the older half of a page's record", true
		}
		return "", false
	}); ok {
		return s, true
	}
	if s, ok := pages(func(p map[string]any) (string, bool) {
		if p["screenshot"] != nil {
			delete(p, "screenshot")
			return "a page's screenshot", true
		}
		return "", false
	}); ok {
		return s, true
	}
	if keep >= 0 {
		m := calls[keep].(map[string]any)
		delete(m, "result")
		m["left_out"] = "size"
		return "the answer of the newest call with a picture", true
	}
	return "", false
}

// smallVersion is the report without the chat's calls, logs and parts, for an intake that takes
// only 64 KB (FR-1451).
func smallVersion(t map[string]any) ([]byte, error) {
	small := map[string]any{}
	for k, v := range t {
		switch k {
		case "calls", "relay_log", "parts":
		default:
			small[k] = v
		}
	}
	small["left_out"] = append(withoutSizeNotes(asList(t["left_out"])),
		"the chat's calls, the logs and the machines' parts: the intake took only small reports")
	b, err := json.Marshal(small)
	if err == nil && len(b) > reports.OldMaxSealed-sizeMargin {
		small["details"] = truncate(fmt.Sprint(small["details"]), 8000)
		b, err = json.Marshal(small)
	}
	return b, err
}
