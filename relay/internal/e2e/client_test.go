package e2e

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// The first local eval run (2026-11-27): the evals took a token for each of their 60 tries, each
// with a new client registration, and the relay registers 10 at once and then one a minute per
// address: every try after the twelfth failed with "registration failed". A relay's client is
// registered once and reused, with any loopback redirect port.
func TestAClientIsRegisteredOncePerRelay(t *testing.T) {
	var registrations atomic.Int32
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/register" || r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		if registrations.Add(1) > 10 { // the relay's limit: 10 at once
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"client_id":"client-1"}`))
	}))
	defer relay.Close()
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"client_id":"client-2"}`))
	}))
	defer other.Close()

	b := &Browser{}
	ctx := context.Background()
	for i := range 60 {
		id, err := b.clientFor(ctx, relay.URL, "http://127.0.0.1:"+string(rune('0'+i%10))+"/callback")
		if err != nil || id != "client-1" {
			t.Fatalf("try %d: client %q, %v", i+1, id, err)
		}
	}
	if n := registrations.Load(); n != 1 {
		t.Fatalf("%d registrations for 60 tokens, want 1", n)
	}
	if id, err := b.clientFor(ctx, other.URL, "http://127.0.0.1:1/callback"); err != nil || id != "client-2" {
		t.Fatalf("another relay: client %q, %v; want its own", id, err)
	}
}

func TestARefusedRegistrationSaysItsStatus(t *testing.T) {
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer relay.Close()
	_, err := (&Browser{}).clientFor(context.Background(), relay.URL, "http://127.0.0.1:1/callback")
	if err == nil || !contains(err.Error(), "HTTP 429") {
		t.Fatalf("error %v, want it to name HTTP 429", err)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
