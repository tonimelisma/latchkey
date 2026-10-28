package events

import (
	"context"
	"sync"
)

// A request's note: what the handler knows about a refusal or failure that the response's status
// alone doesn't say (the reason, and the account when there is one). The relay's outermost
// handler puts an empty note in each request's context, records the request as refused or
// failed when it ends with an error status, and uses the note for the detail. Reasons are fixed
// words, never anything the client sent.
type requestNote struct {
	mu     sync.Mutex
	reason string
	userID string
}

type noteKey struct{}

// WithNote gives the request's context a note and returns a function that reads it.
func WithNote(ctx context.Context) (context.Context, func() (reason, userID string)) {
	n := &requestNote{}
	return context.WithValue(ctx, noteKey{}, n), func() (string, string) {
		n.mu.Lock()
		defer n.mu.Unlock()
		return n.reason, n.userID
	}
}

// Note sets the reason of the request's refusal or failure; the first reason wins.
func Note(ctx context.Context, reason string) {
	if n, ok := ctx.Value(noteKey{}).(*requestNote); ok {
		n.mu.Lock()
		if n.reason == "" {
			n.reason = reason
		}
		n.mu.Unlock()
	}
}

// NoteUser names the account the request belongs to.
func NoteUser(ctx context.Context, userID string) {
	if n, ok := ctx.Value(noteKey{}).(*requestNote); ok {
		n.mu.Lock()
		n.userID = userID
		n.mu.Unlock()
	}
}
