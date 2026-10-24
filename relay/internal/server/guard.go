package server

import (
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/auth"

	"github.com/tonimelisma/latchkey/relay/internal/limit"
)

// Request body caps. MCP requests carry tool arguments (a file written through Claude, say);
// everything else is a small form or JSON object.
const (
	maxMCPBody   = 16 << 20
	maxOtherBody = 1 << 20
)

// rule is one abuse limit: which requests it covers and its per-key bucket.
type rule struct {
	match func(*http.Request) bool
	per   *limit.Keyed
}

// The limits sit far above what an owner, their Macs, and Claude do in normal use; they only
// slow down guessing, flooding, and table-filling. Claude calls /token and /register from
// Anthropic's shared egress range, so those limits are the loosest.
func defaultRules() []rule {
	post := func(prefixes ...string) func(*http.Request) bool {
		return func(r *http.Request) bool {
			if r.Method != http.MethodPost {
				return false
			}
			for _, p := range prefixes {
				if strings.HasPrefix(r.URL.Path, p) {
					return true
				}
			}
			return false
		}
	}
	path := func(p string) func(*http.Request) bool {
		return func(r *http.Request) bool { return r.URL.Path == p }
	}
	return []rule{
		// Sign-in, passkeys, pairing, account changes: 20 at once, then one every 3 s.
		{post("/auth/", "/passkey/", "/pair", "/account/", "/signout"), limit.NewKeyed(20, 3*time.Second)},
		// Client registration (RFC 7591): 10 at once, then one a minute.
		{post("/register"), limit.NewKeyed(10, time.Minute)},
		// Consent page.
		{path("/authorize"), limit.NewKeyed(60, time.Second)},
		// Token and revocation endpoints: secrets are needed anyway; this only stops floods.
		{post("/token", "/revoke"), limit.NewKeyed(300, 100*time.Millisecond)},
		// Mac connections: a reconnecting Mac retries every few seconds at most.
		{path("/agent/v1"), limit.NewKeyed(30, 2*time.Second)},
	}
}

// guard wraps the relay with security headers, body caps, and per-address abuse limits.
func guard(public *url.URL, next http.Handler) http.Handler {
	rules := defaultRules()
	hsts := public != nil && public.Scheme == "https"
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// Pages set their own Content-Security-Policy; everything else loads nothing.
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()")
		if !strings.HasPrefix(r.URL.Path, "/static/") {
			h.Set("Cache-Control", "no-store")
		}
		if hsts {
			h.Set("Strict-Transport-Security", "max-age=63072000")
		}

		ip := limit.ClientIP(r)
		for _, rl := range rules {
			if rl.match(r) && !rl.per.Allow(ip) {
				tooMany(w)
				return
			}
		}

		if r.Body != nil {
			max := int64(maxOtherBody)
			if r.URL.Path == "/mcp" {
				max = maxMCPBody
			}
			if r.ContentLength > max {
				http.Error(w, "Request too large.", http.StatusRequestEntityTooLarge)
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, max)
		}
		next.ServeHTTP(w, r)
	})
}

// perUser limits MCP calls per signed-in owner, after the token is checked: 120 at once, then
// ten a second. A leaked token can't flood the owner's Mac.
func perUser(next http.Handler) http.Handler {
	users := limit.NewKeyed(120, 100*time.Millisecond)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if info := auth.TokenInfoFromContext(r.Context()); info != nil && !users.Allow(info.UserID) {
			tooMany(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func tooMany(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "60")
	http.Error(w, "Too many requests. Wait a minute and try again.", http.StatusTooManyRequests)
}
