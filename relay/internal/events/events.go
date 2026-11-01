// Package events is the relay's event record (FR-631, FR-635): each event is stored, kept until
// its account is deleted, and written to the relay's output as one readable line. Refused and
// failed requests are counted per hour instead of stored one by one (Count), so no stranger can
// grow the database or the output without bound.
package events

import (
	"context"
	"log/slog"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Kinds of events (FR-631). Details are fixed words the relay chooses, never content, tokens,
// codes, keys, or IP addresses.
const (
	MacConnected    = "mac_connected"    // detail: app and macOS version, keep-awake
	MacDisconnected = "mac_disconnected" // detail: close code and reason, goodbye reason
	MacRefused      = "mac_refused"      // counted; detail: why the handshake was refused
	KeepAwake       = "keep_awake"       // detail: the new keep-awake state, and the one before
	SignInPasskey   = "sign_in_passkey"  // detail: outcome
	SignInCode      = "sign_in_code"     // emailed code at sign-up; detail: outcome
	Recovery        = "recovery"         // emailed recovery code; detail: outcome
	ClaudeApproved  = "claude_approved"  // detail: the app's name and host, as on the consent page
	ClaudeRefused   = "claude_refused"   // the Owner declined on the consent page
	ClaudeRemoved   = "claude_removed"   // detail: the app and who or what removed it
	MacPaired       = "mac_paired"
	MacUnpaired     = "mac_unpaired"    // detail: who or what unpaired it
	RequestRefused  = "request_refused" // counted; detail: route, status, reason
	RequestFailed   = "request_failed"  // counted; detail: route, status, reason
	AccountDeleted  = "account_deleted" // logged only: its record goes with the account
)

// Kinds lists every kind.
var Kinds = []string{
	MacConnected, MacDisconnected, MacRefused, KeepAwake, SignInPasskey, SignInCode, Recovery,
	ClaudeApproved, ClaudeRefused, ClaudeRemoved, MacPaired, MacUnpaired, RequestRefused,
	RequestFailed, AccountDeleted,
}

var titles = map[string]string{
	MacConnected:    "Mac connected",
	MacDisconnected: "Mac disconnected",
	MacRefused:      "Mac connection refused",
	KeepAwake:       "keep-awake changed",
	SignInPasskey:   "passkey sign-in",
	SignInCode:      "emailed code sign-in",
	Recovery:        "account recovery",
	ClaudeApproved:  "Claude app approved",
	ClaudeRefused:   "Claude app refused",
	ClaudeRemoved:   "Claude app removed",
	MacPaired:       "Machine paired",
	MacUnpaired:     "Machine unpaired",
	RequestRefused:  "request refused",
	RequestFailed:   "request failed",
	AccountDeleted:  "account deleted",
}

// Title is the words of a kind's log line.
func Title(kind string) string {
	if t, ok := titles[kind]; ok {
		return t
	}
	return kind
}

// Recorder records events. A nil Recorder records nothing.
type Recorder struct {
	store *store.Store
	log   *slog.Logger
	now   func() time.Time
}

// New makes a recorder; now nil means time.Now.
func New(st *store.Store, log *slog.Logger, now func() time.Time) *Recorder {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	return &Recorder{store: st, log: log, now: now}
}

// Record stores the event and logs it. The time is now unless e.At is set. The write survives
// the caller's cancellation: a request that ends doesn't take its event with it.
func (r *Recorder) Record(ctx context.Context, e store.Event) {
	if r == nil {
		return
	}
	if e.At.IsZero() {
		e.At = r.now().UTC()
	}
	r.line(e, false)
	if r.store == nil {
		return
	}
	if err := r.store.AddEvent(context.WithoutCancel(ctx), e); err != nil {
		r.log.Error("record event", "event", e.Kind, "err", err)
	}
}

// Count adds the event to its hour's count (refused and failed requests): the first of each hour
// is logged, the rest only counted.
func (r *Recorder) Count(ctx context.Context, e store.Event) {
	if r == nil {
		return
	}
	if e.At.IsZero() {
		e.At = r.now().UTC()
	}
	if r.store == nil {
		r.line(e, true)
		return
	}
	first, err := r.store.CountEvent(context.WithoutCancel(ctx), e)
	if err != nil {
		r.log.Error("record event", "event", e.Kind, "err", err)
		first = true // the record failed: the output keeps it at least
	}
	if first {
		r.line(e, true)
	}
}

// Log writes the event's line without storing it: for an event whose record would go at once,
// such as the account's deletion.
func (r *Recorder) Log(e store.Event) {
	if r != nil {
		r.line(e, false)
	}
}

func (r *Recorder) line(e store.Event, counted bool) {
	attrs := []any{"event", e.Kind}
	if e.UserID != "" {
		attrs = append(attrs, "user", e.UserID)
	}
	if e.DeviceID != "" {
		attrs = append(attrs, "device", e.DeviceID)
	}
	if e.Detail != "" {
		attrs = append(attrs, "detail", e.Detail)
	}
	if counted {
		attrs = append(attrs, "counted", "first this hour; later ones are counted, not logged")
	}
	r.log.Info(Title(e.Kind), attrs...)
}
