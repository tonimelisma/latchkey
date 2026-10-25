package server

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
)

// sampleOperator is a made-up person running a relay; every detail must come from here.
var sampleOperator = account.Operator{
	Name: "Sample Operator", Contact: "relay-owner@example.org", Law: "Ruritania",
	Providers: "Example Cloud (hosting) and Example Mail (email delivery)", BackupDays: 14,
}

func withOperator(op account.Operator) func(*Options) {
	return func(o *Options) { o.Operator = op }
}

const (
	termsLink   = `<a href="/terms">Terms</a>`
	privacyLink = `<a href="/privacy">Privacy</a>`
)

// With the operator's name and contact set, the relay publishes both documents, readable on a
// phone, without scripts, with the pages' security headers, and with the operator's details
// (FR-193, FR-194).
func TestTermsAndPrivacyPagesWhenTheOperatorIsNamed(t *testing.T) {
	h := newHarness(t, withOperator(sampleOperator))
	for path, title := range map[string]string{"/terms": "Terms of Service", "/privacy": "Privacy Policy"} {
		r := h.get(path)
		require.Equal(t, http.StatusOK, r.status, path)
		assert.Contains(t, r.body, "<h1>"+title+"</h1>", path)
		assert.Contains(t, r.body, "Sample Operator", path)
		assert.Contains(t, r.body, `<a href="mailto:relay-owner@example.org">relay-owner@example.org</a>`, path)
		assert.Contains(t, r.body, "Effective "+account.LegalEffectiveDate, path)
		assert.Contains(t, r.body, `<meta name="viewport" content="width=device-width, initial-scale=1">`, path)
		assert.NotContains(t, strings.ToLower(r.body), "<script", "%s: no scripts", path)
		assert.Contains(t, r.header.Get("Content-Type"), "text/html", path)
		assert.Contains(t, r.header.Get("Content-Security-Policy"), "default-src 'self'", path)
		assert.Equal(t, "DENY", r.header.Get("X-Frame-Options"), path)
		assert.Equal(t, "nosniff", r.header.Get("X-Content-Type-Options"), path)
		assert.Contains(t, r.body, termsLink, path)
		assert.Contains(t, r.body, privacyLink, path)
		assert.NotContains(t, r.body, "<no value>", path)
	}
	terms, privacy := h.get("/terms").body, h.get("/privacy").body
	assert.Contains(t, terms, "governed by the laws of Ruritania")
	assert.Contains(t, privacy, "Example Cloud (hosting) and Example Mail (email delivery)")
	assert.Contains(t, privacy, "14 days")
	assert.Contains(t, terms, "Apache")
}

// The optional settings add their sentences only when given.
func TestOptionalLegalSentencesAppearOnlyWhenSet(t *testing.T) {
	h := newHarness(t, withOperator(account.Operator{Name: "Sample Operator", Contact: "relay-owner@example.org"}))
	terms, privacy := h.get("/terms").body, h.get("/privacy").body
	assert.NotContains(t, terms, "governed by")
	assert.NotContains(t, strings.ToLower(privacy), "backup")
	assert.Contains(t, privacy, "hosting and email providers")
	assert.NotContains(t, privacy, "<no value>")
}

// Every page the relay shows links both documents in its footer.
func TestEveryPageLinksTermsAndPrivacy(t *testing.T) {
	h := newHarness(t, withOperator(sampleOperator))
	o := h.owner("owner@example.com")
	client := h.registerClient(claudeCallback)
	q := url.Values{
		"response_type": {"code"}, "client_id": {client}, "redirect_uri": {claudeCallback}, "scope": {"mcp"},
		"state": {"state-123456789"}, "code_challenge": {"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"}, "code_challenge_method": {"S256"},
	}
	pages := map[string]reply{
		"home":    h.get("/"),
		"sign-in": h.get("/signin"),
		"account": o.get("/account"),
		"pair":    o.get("/pair?name=Mac"),
		"consent": o.get("/authorize?" + q.Encode()),
		"message": o.form("/account/revoke-mac", url.Values{"csrf": {"wrong"}}),
		"terms":   h.get("/terms"),
		"privacy": h.get("/privacy"),
	}
	for name, r := range pages {
		assert.Contains(t, r.body, "</main>", "%s is a page (HTTP %d)", name, r.status)
		assert.Contains(t, r.body, termsLink, name)
		assert.Contains(t, r.body, privacyLink, name)
	}
	assert.Contains(t, pages["consent"].body, "Allow Claude")
	assert.Contains(t, pages["message"].body, "This form expired")
}

// Where an account is created, the page says what continuing means.
func TestSignUpStepNamesTheAgreement(t *testing.T) {
	h := newHarness(t, withOperator(sampleOperator))
	body := h.get("/signin").body
	assert.Contains(t, body, `By continuing, you agree to the <a href="/terms">Terms</a> and the <a href="/privacy">Privacy Policy</a>.`)
	email := strings.Index(body, `data-step="email"`)
	passkey := strings.Index(body, `data-step="passkey"`)
	at := strings.Index(body, "By continuing, you agree")
	assert.True(t, email < at && at < passkey, "in the email step")
}

func metadata(t *testing.T, h *harness) map[string]any {
	t.Helper()
	r := h.get("/.well-known/oauth-authorization-server")
	require.Equal(t, http.StatusOK, r.status)
	var m map[string]any
	require.NoError(t, json.Unmarshal([]byte(r.body), &m))
	return m
}

// Claude's clients are told where the documents are (RFC 8414 op_tos_uri, op_policy_uri).
func TestMetadataAdvertisesTheDocuments(t *testing.T) {
	h := newHarness(t, withOperator(sampleOperator))
	m := metadata(t, h)
	assert.Equal(t, h.base+"/terms", m["op_tos_uri"])
	assert.Equal(t, h.base+"/privacy", m["op_policy_uri"])
}

// A relay whose operator set nothing (a personal relay for oneself) has no documents, no
// links, no sentence, and no metadata fields.
func TestNoDocumentsWithoutAnOperator(t *testing.T) {
	h := newHarness(t, nil)
	o := h.owner("owner@example.com")
	assert.Equal(t, http.StatusNotFound, h.get("/terms").status)
	assert.Equal(t, http.StatusNotFound, h.get("/privacy").status)
	for name, r := range map[string]reply{"home": h.get("/"), "sign-in": h.get("/signin"), "account": o.get("/account")} {
		assert.Contains(t, r.body, "</main>", name)
		assert.NotContains(t, r.body, "/terms", name)
		assert.NotContains(t, r.body, "/privacy", name)
		assert.NotContains(t, r.body, "By continuing", name)
	}
	m := metadata(t, h)
	assert.NotContains(t, m, "op_tos_uri")
	assert.NotContains(t, m, "op_policy_uri")
}
