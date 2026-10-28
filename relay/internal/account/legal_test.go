package account_test

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

var operator = account.Operator{
	Name: "Sample Operator", Contact: "relay-owner@example.org", Law: "Ruritania",
	Providers: "Example Cloud (hosting) and Example Mail (email delivery)", BackupDays: 14,
}

func legalPage(t *testing.T, path string) string {
	t.Helper()
	e := setupWith(t, func(c *account.Config) { c.Operator = operator })
	r := e.browser().get(path)
	require.Equal(t, 200, r.status)
	return r.body
}

// storedData is what the privacy policy must say about each table the relay keeps: one phrase
// per table of specs/001-core/data-model.md. A new table needs a line here and words in
// templates/privacy.html, or this test fails (FR-194).
var storedData = map[string]string{
	"users":                 "Your email address",
	"passkeys":              "Your passkeys' public keys",
	"email_tokens":          "The codes we email you",
	"web_sessions":          "A record of each browser you are signed in with",
	"devices":               "Your Mac's name",
	"device_state":          "Your Mac's last reported state",
	"pairing_codes":         "The one-time code that connects your Mac",
	"relay_keys":            "The relay's own secret keys",
	"oauth_clients":         "A description of each Claude app",
	"oauth_requests":        "The sign-in codes and access tokens",
	"oauth_grants":          "Which Claude apps you approved",
	"client_authorizations": "A note of each approval",
	"audit_log":             "An activity log",
	"events":                "A record of events on your account",
	"blocked_emails":        "A list of blocked email addresses",
	"operator_log":          "A record of what the operator did",
}

var entityRE = regexp.MustCompile(`(?m)^\| \*\*([a-z_]+)\*\* \|`)

func TestPrivacyPolicyNamesEveryStoredTable(t *testing.T) {
	policy := legalPage(t, "/privacy")

	// Every table in the data model has a phrase, and the policy says it.
	doc, err := os.ReadFile("../../../specs/001-core/data-model.md")
	require.NoError(t, err)
	var documented []string
	for _, m := range entityRE.FindAllStringSubmatch(string(doc), -1) {
		documented = append(documented, m[1])
	}
	require.GreaterOrEqual(t, len(documented), 12, "data-model.md's table was not found")
	for _, table := range documented {
		phrase, ok := storedData[table]
		if assert.True(t, ok, "data-model.md lists %q: say in the privacy policy what it holds, and add it to storedData", table) {
			assert.Contains(t, policy, phrase, "the privacy policy must say what %q holds", table)
		}
	}
	for table := range storedData {
		assert.Contains(t, documented, table, "storedData names %q, which data-model.md doesn't list", table)
	}

	// And every table in the database is in the data model.
	path := filepath.Join(t.TempDir(), "relay.db")
	st, err := store.Open(context.Background(), path)
	require.NoError(t, err)
	require.NoError(t, st.Close())
	db, err := sql.Open("sqlite", "file:"+path)
	require.NoError(t, err)
	defer func() { _ = db.Close() }()
	rows, err := db.QueryContext(context.Background(),
		`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'goose_%'`)
	require.NoError(t, err)
	defer func() { _ = rows.Close() }()
	n := 0
	for rows.Next() {
		var name string
		require.NoError(t, rows.Scan(&name))
		n++
		assert.Contains(t, documented, name, "table %q is in the database but not in data-model.md (and so not in the privacy policy)", name)
	}
	require.NoError(t, rows.Err())
	assert.GreaterOrEqual(t, n, 12)
}

// The policy says what is never stored, how long things are kept, and the rest the directory
// policy asks for: collection, use, retention, contact.
func TestPrivacyPolicyCoversWhatItMust(t *testing.T) {
	policy := legalPage(t, "/privacy")
	for _, want := range []string{
		"never stored", // tool results pass through
		"in transit",   // and can technically be seen there
		"Anthropic",    // Claude is someone else's service
		"30 days",      // notes of approvals, access log
		"until you delete your account. Nothing in them is deleted because of its age", // FR-630
		"15 minutes",                // emailed codes
		"Delete account",            // deletion
		"do not sell",               // sharing
		"advertising",               //
		"under 18",                  // children
		"California",                // rights, in general terms
		"European",                  //
		"relay-owner@example.org",   // how to ask
		"14 days",                   // backups
		"one year",                  // operator log
		"We may change this policy", // changes
	} {
		assert.Contains(t, policy, want)
	}
}

func TestTermsCoverWhatTheyMust(t *testing.T) {
	terms := legalPage(t, "/terms")
	for _, want := range []string{
		"18", "your own Mac", "passkey", "suspend", "as is", "Apache", "Ruritania",
		"relay-owner@example.org", "We may change these terms",
	} {
		assert.Contains(t, terms, want)
	}
}

// Nothing about any particular operator is written into the software: the documents' source
// holds no address, name, place, or site of its own (FR-194).
func TestLegalTemplatesHoldNoOperatorDetails(t *testing.T) {
	email := regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}`)
	link := regexp.MustCompile(`https?://[^\s"<]+`)
	for _, name := range []string{"templates/terms.html", "templates/privacy.html", "templates/base.html", "legal.go"} {
		src, err := os.ReadFile(name)
		require.NoError(t, err)
		text := string(src)
		assert.Empty(t, email.FindAllString(text, -1), "%s: an email address is written in", name)
		for _, l := range link.FindAllString(text, -1) {
			assert.True(t, strings.HasPrefix(l, "https://www.anthropic.com/") || strings.HasPrefix(l, "https://www.apache.org/"),
				"%s: link to %s", name, l)
		}
		for _, place := range []string{"Ruritania", "United States", "USA", "Sample Operator"} {
			assert.NotContains(t, text, place, name)
		}
	}
	// "California" appears only where the policy speaks of residents' rights, never as the
	// operator's place.
	terms, err := os.ReadFile("templates/terms.html")
	require.NoError(t, err)
	assert.NotContains(t, string(terms), "California")
}

func TestOperatorSettingsAreChecked(t *testing.T) {
	ok := []account.Operator{
		{},
		{Name: "A Person", Contact: "a@example.org"},
		{Name: "A Person", Contact: "a@example.org", Law: "Ruritania", Providers: "x", BackupDays: 7},
		{Law: "Ruritania", BackupDays: 3}, // unused without a name and contact
	}
	for _, o := range ok {
		require.NoError(t, o.Validate(), "%+v", o)
	}
	bad := map[string]account.Operator{
		"name without contact": {Name: "A Person"},
		"contact without name": {Contact: "a@example.org"},
		"contact not an email": {Name: "A Person", Contact: "the front desk"},
		"contact with a name":  {Name: "A Person", Contact: "A Person <a@example.org>"},
		"negative backup days": {Name: "A Person", Contact: "a@example.org", BackupDays: -1},
	}
	for name, o := range bad {
		require.Error(t, o.Validate(), name)
	}
	assert.True(t, ok[1].Published())
	assert.False(t, ok[0].Published())
	assert.False(t, ok[3].Published())
}
