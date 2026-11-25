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
	// clientLookBack is the span for a client without sessions (FR-1441).
	clientLookBack = 2 * time.Hour
	// sizeMargin leaves room for sealing (the KEM's encapsulation, the tag, the magic).
	sizeMargin = 4 << 10
)

// pageName is the shape of a page name Latchkey gives (spec 005 FR-444; OwnPages.newName).
var pageName = regexp.MustCompile(`^p[abcdefghjkmnpqrstuvwxyz23456789]{4}$`)

// pageInAnswer finds the page names an answer gives ("page p4k2").
var pageInAnswer = regexp.MustCompile(`\bpage (p[abcdefghjkmnpqrstuvwxyz23456789]{4})\b`)

// codeLike is an argument that has the shape of a verification code: 4 to 8 digits (FR-1448).
var codeLike = regexp.MustCompile(`^[0-9]{4,8}$`)

// secretKeys are argument names whose value is a secret wherever they appear (FR-1448), and
// secretParts are parts of a name that make it one (api_key, access_token, client_secret);
// security review 2026-11-25.
var (
	secretKeys  = map[string]bool{"code": true, "password": true, "passcode": true, "otp": true, "pin": true, "passphrase": true}
	secretParts = []string{"password", "passwd", "token", "secret", "apikey", "api_key", "authorization", "cookie", "credential", "private_key"}
	// bearerLike finds a credential written into text (a header in a shell command).
	bearerLike = regexp.MustCompile(`(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{16,}`)
)

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

// chatOf reads the account's trace for the chat the request came in on (FR-1441).
func (s *Server) chatOf(userID, session, client string, now time.Time) chat {
	c := chat{from: now, to: now}
	if s.opts.Traces == nil {
		return c
	}
	var all []trace.Line
	from := now.Add(-chatLookBack).UTC().Format(trace.DayFormat)
	_, err := s.opts.Traces.Each(userID, from, now.UTC().Format(trace.DayFormat), func(l trace.Line) error {
		all = append(all, l)
		return nil
	})
	if err != nil {
		s.opts.Logger.Warn("report: the trace couldn't be read", "user", userID, "err", err)
	}
	at := func(l trace.Line) time.Time { t, _ := time.Parse(time.RFC3339Nano, l.Time); return t }
	in := map[string]bool{}
	pages := map[string]bool{}
	notePages := func(l trace.Line) {
		var args map[string]any
		if json.Unmarshal(l.Arguments, &args) == nil {
			if p, ok := args["page"].(string); ok && pageName.MatchString(strings.ToLower(strings.TrimSpace(p))) {
				pages[strings.ToLower(strings.TrimSpace(p))] = true
			}
		}
		for _, m := range pageInAnswer.FindAllStringSubmatch(string(l.Result), -1) {
			pages[m[1]] = true
		}
	}
	usesPage := func(l trace.Line) bool {
		var args map[string]any
		if json.Unmarshal(l.Arguments, &args) == nil {
			if p, ok := args["page"].(string); ok && pages[strings.ToLower(strings.TrimSpace(p))] {
				return true
			}
		}
		return false
	}
	switch {
	case session != "":
		c.how = "session"
		in[session] = true
		// The chat's own session, then each earlier one that worked in one of its pages, until
		// nothing more joins (a chat idle 30 minutes goes on in a new session).
		for range 8 {
			for _, l := range all {
				if l.Kind == trace.KindAction && in[l.Session] {
					notePages(l)
				}
			}
			grew := false
			for _, l := range all {
				if l.Kind == trace.KindAction && l.Session != "" && !in[l.Session] && usesPage(l) && now.Sub(at(l)) <= chatLookBack {
					in[l.Session] = true
					grew = true
				}
			}
			if !grew {
				break
			}
		}
		for _, l := range all {
			if l.Kind == trace.KindAction && in[l.Session] {
				c.calls = append(c.calls, l)
			}
		}
		c.sessions = len(in)
	default:
		c.how = "client and time"
		for _, l := range all {
			if l.Kind == trace.KindAction && l.Client == client && now.Sub(at(l)) <= clientLookBack {
				c.calls = append(c.calls, l)
				notePages(l)
			}
		}
	}
	sort.SliceStable(c.calls, func(i, j int) bool { return at(c.calls[i]).Before(at(c.calls[j])) })
	if len(c.calls) > 0 {
		c.from = at(c.calls[0])
	}
	for _, l := range all {
		if l.Kind == trace.KindEvent && !at(l).Before(c.from) {
			c.events = append(c.events, l)
		}
	}
	for p := range pages {
		c.pages = append(c.pages, p)
	}
	sort.Strings(c.pages)
	return c
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
func (s *Server) fullReport(ctx context.Context, userID string, req *mcp.CallToolRequest, client string,
	ms []machine, named []string, r reports.Report, now time.Time,
) (full, small []byte, err error) {
	c := s.chatOf(userID, sessionOf(req), client, now)
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

	var scrub []string // old, new pairs, applied to every string of the report
	for _, v := range secretsIn(r.Calls) {
		scrub = append(scrub, v, "(blanked)")
	}
	names := make([]string, 0, len(ms))
	for _, m := range ms {
		if len(m.Device.Name) >= 3 {
			names = append(names, m.Device.Name)
		}
	}
	sort.Slice(names, func(i, j int) bool { return len(names[i]) > len(names[j]) }) // longest first
	for _, n := range names {
		scrub = append(scrub, n, label(n))
	}
	if u, err := s.store.User(ctx, userID); err == nil && u.Email != "" {
		scrub = append(scrub, u.Email, "(the account's email)")
	}
	if s.opts.PublicURL != nil && s.opts.PublicURL.Host != "" {
		scrub = append(scrub, s.opts.PublicURL.Host, "(the relay)")
	}

	tree, err := toTree(r)
	if err != nil {
		return nil, nil, err
	}
	tree = scrubTree(tree, strings.NewReplacer(scrub...), "")
	full, err = fit(tree.(map[string]any), reports.MaxSealed-sizeMargin)
	if err != nil {
		return nil, nil, err
	}
	small, err = smallVersion(tree.(map[string]any))
	return full, small, err
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
			if len(t) >= 4 && (secretKey(key) || codeLike.MatchString(t)) && !seen[t] {
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

// scrubTree replaces the secrets and names in every string of the report, except where a
// replaced byte would break what isn't text and holds nothing Claude passed (security review
// 2026-11-25: exemptions go by place, not by a key name an argument could also have): a
// picture's data (an object of type image, or a page's screenshot), the report's own id and
// time, and the time and call id the relay gave each call.
func scrubTree(v any, r *strings.Replacer, key string) any { return scrubAt(v, r, key, "", nil) }

func scrubAt(v any, r *strings.Replacer, key, where string, parent map[string]any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, vv := range x {
			x[k] = scrubAt(vv, r, k, where+"/"+k, x)
		}
		return x
	case []any:
		for i, vv := range x {
			x[i] = scrubAt(vv, r, key, where+"/[]", parent)
		}
		return x
	case string:
		image := key == "data" && parent != nil && (parent["type"] == "image" || strings.HasSuffix(where, "/screenshot/data"))
		switch {
		case image, where == "/id", where == "/at", where == "/calls/[]/time", where == "/calls/[]/call_id",
			where == "/chat/from", where == "/chat/to":
			return x
		}
		return r.Replace(x)
	}
	return v
}

// fit marshals the report, leaving out its oldest parts until it is at most limit bytes
// (FR-1450): answers of the oldest calls first (the newest call with a picture last), then the
// machines' traces, the oldest log lines, page sources, page records, screenshots.
func fit(t map[string]any, limit int) ([]byte, error) {
	base := asList(t["left_out"])
	counts := map[string]int{}
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
