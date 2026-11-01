package account

import (
	"context"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/events"
)

const (
	recentEntries   = 10 // on the account page (FR-651)
	activityPerPage = 50 // on the activity page (FR-652)
)

// ownerEvents are the account events the Owner sees in their activity, with the words shown for
// each (FR-653). Connection drops, keep-awake changes, and refused requests stay in the
// operator's record: they are many, and say little the machine's own state doesn't.
var ownerEvents = map[string]string{
	events.SignInPasskey:  "Signed in with a passkey",
	events.SignInCode:     "Signed up",
	events.Recovery:       "Account recovery",
	events.ClaudeApproved: "Claude app allowed",
	events.ClaudeRefused:  "Claude app not allowed",
	events.ClaudeRemoved:  "Claude app removed",
	events.MacPaired:      "Machine connected",
	events.MacUnpaired:    "Machine removed",
}

var ownerEventKinds = func() []string {
	kinds := make([]string, 0, len(ownerEvents))
	for k := range ownerEvents {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	return kinds
}()

// entry is one line of the Owner's activity: a tool call, or an account event.
type entry struct {
	At       time.Time
	Event    bool   // an account event rather than a tool call
	What     string // the tool's name, or the event's words
	Machine  string
	Outcome  string // a call's ok, error, timeout, or offline
	Duration time.Duration
	Surface  string
	Detail   string // an event's detail, as the relay wrote it
	Count    int    // an event counted over an hour
}

// activity returns the account's entries from before the given time (all when zero), newest
// first, at least limit when there are that many. A page never ends inside a millisecond: entries
// that share the last entry's time all go on this page, so the next page, which starts before
// that time, skips none (FR-652).
func (s *Service) activity(ctx context.Context, userID string, before time.Time, limit int) ([]entry, bool, error) {
	calls, err := s.cfg.Store.AuditForUserBefore(ctx, userID, before, limit+1)
	if err != nil {
		return nil, false, err
	}
	evs, err := s.cfg.Store.EventsBefore(ctx, userID, ownerEventKinds, before, limit+1)
	if err != nil {
		return nil, false, err
	}
	names := map[string]string{}
	machine := func(id string) string {
		if id == "" {
			return ""
		}
		if n, ok := names[id]; ok {
			return n
		}
		n := ""
		if d, err := s.cfg.Store.Device(ctx, id); err == nil {
			n = d.Name
			if !d.RevokedAt.IsZero() {
				n += " (removed)"
			}
		}
		names[id] = n
		return n
	}
	out := make([]entry, 0, len(calls)+len(evs))
	for _, c := range calls {
		out = append(out, entry{At: c.At, What: c.Tool, Machine: machine(c.DeviceID), Outcome: c.Outcome, Duration: c.Duration, Surface: c.Surface})
	}
	for _, e := range evs {
		out = append(out, entry{At: e.At, Event: true, What: ownerEvents[e.Kind], Machine: machine(e.DeviceID), Detail: ownerDetail(e.Detail), Count: e.Count})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	more := len(out) > limit
	if more {
		cut := limit
		for cut < len(out) && out[cut].At.UnixMilli() == out[limit-1].At.UnixMilli() {
			cut++
		}
		more = cut < len(out)
		out = out[:cut]
	}
	return out, more, nil
}

type activityView struct {
	Entries []entry
	Older   string // the next page's address, "" on the last
	Newest  bool   // the first page
}

// activityPage is GET /account/activity: every tool call and account event, newest first, a page
// at a time (FR-652).
func (s *Service) activityPage(w http.ResponseWriter, r *http.Request) {
	u, tok, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	var before time.Time
	if ms, err := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64); err == nil && ms > 0 {
		before = time.UnixMilli(ms).UTC()
	}
	list, more, err := s.activity(r.Context(), u.ID, before, activityPerPage)
	if err != nil {
		s.errorPage(w, http.StatusInternalServerError, "Activity isn't available right now", "Try again in a moment.")
		return
	}
	v := activityView{Entries: list, Newest: before.IsZero()}
	if more {
		v.Older = "/account/activity?before=" + strconv.FormatInt(list[len(list)-1].At.UnixMilli(), 10)
	}
	s.render(w, http.StatusOK, "activity.html", page{Title: "Activity", Email: u.Email, CSRF: s.csrfFor(tok), Data: v, Wide: true})
}

// ownerDetail is an event's detail without the words its title already says: "signed in" adds
// nothing to "Signed in with a passkey", and "signed up: address confirmed…" keeps only what
// follows the colon.
func ownerDetail(d string) string {
	switch {
	case d == "signed in":
		return ""
	case strings.HasPrefix(d, "signed up: "):
		return strings.TrimPrefix(d, "signed up: ")
	case strings.HasPrefix(d, "account recovered: "):
		return strings.TrimPrefix(d, "account recovered: ")
	}
	return d
}

// slowCall is how long a call takes before the activity shows its duration; quicker ones that
// went well show none, which keeps the list short to read.
const slowCall = 2 * time.Second

// surfaceName is a Claude app's name as the activity shows it: "claude-code" is "Claude Code".
// The name comes from the client, cleaned when stored (FR-022a); unknown ones are shown as given.
func surfaceName(s string) string {
	switch strings.ToLower(s) {
	case "claude-code":
		return "Claude Code"
	case "claude-ai", "claude.ai":
		return "Claude"
	case "claude-desktop":
		return "Claude Desktop"
	}
	return s
}

// outcomeWords is a call's outcome as the activity shows it.
func outcomeWords(o string) string {
	switch o {
	case "ok":
		return "Done"
	case "error":
		return "Error"
	case "timeout":
		return "Timed out"
	case "offline":
		return "Offline"
	}
	return o
}

// took is a call's duration: milliseconds below a second, then seconds with one decimal.
func took(d time.Duration) string {
	if d < time.Second {
		return strconv.FormatInt(d.Milliseconds(), 10) + " ms"
	}
	return strconv.FormatFloat(d.Seconds(), 'f', 1, 64) + " s"
}
