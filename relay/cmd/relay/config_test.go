package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func env(overrides map[string]string) func(string) string {
	base := map[string]string{
		"PUBLIC_URL": "https://relay.example.com",
		"DATA_DIR":   "/data",
		"SMTP_HOST":  "smtp.example.com",
		"SMTP_PORT":  "587",
		"SMTP_FROM":  "Latchkey <no-reply@example.com>",
	}
	for k, v := range overrides {
		base[k] = v
	}
	return func(k string) string { return base[k] }
}

// A personal relay needs no email server when it has a setup code (spec 009 FR-907, FR-908).
func TestLoadConfigSetupCode(t *testing.T) {
	noMail := map[string]string{"SMTP_HOST": "", "SMTP_PORT": "", "SMTP_FROM": ""}
	_, err := loadConfig(env(noMail))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "SETUP_CODE", "neither an email server nor a setup code")

	noMail["SETUP_CODE"] = "K7PQ-M2XD-9RTA"
	c, err := loadConfig(env(noMail))
	require.NoError(t, err)
	assert.Equal(t, "K7PQ-M2XD-9RTA", c.SetupCode)
	assert.Empty(t, c.SMTPHost)

	_, err = loadConfig(env(map[string]string{"SMTP_HOST": "", "SMTP_PORT": "", "SMTP_FROM": "", "SETUP_CODE": "abc123"}))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "12", "a short code could be guessed")

	_, err = loadConfig(env(map[string]string{"SMTP_FROM": "", "SETUP_CODE": "K7PQ-M2XD-9RTA"}))
	require.Error(t, err, "an email server half set up is still an error")
	assert.Contains(t, err.Error(), "SMTP_FROM")
}

func TestLoadConfig(t *testing.T) {
	c, err := loadConfig(env(map[string]string{"SMTP_USER": "u", "SMTP_PASSWORD": "p", "ACME_EMAIL": "a@example.com"}))
	require.NoError(t, err)
	assert.Equal(t, "https://relay.example.com", c.PublicURL.String())
	assert.Equal(t, "/data", c.DataDir)
	assert.Equal(t, 587, c.SMTPPort)
	assert.Equal(t, "u", c.SMTPUser)
	assert.Equal(t, "a@example.com", c.ACMEEmail)
	assert.Equal(t, 8080, c.Port, "default port")

	c, err = loadConfig(env(map[string]string{"PORT": "9000", "ALLOWED_EMAILS": " toni@example.com, ,b@example.com"}))
	require.NoError(t, err)
	assert.Equal(t, 9000, c.Port)
	assert.Equal(t, []string{"toni@example.com", "b@example.com"}, c.AllowedEmails)
	assert.Empty(t, c.TrustedProxies, "loopback only by default")
	assert.Equal(t, []string{"claude.ai"}, c.AllowedClientHosts.Strings(), "Claude's apps only by default")
	assert.Equal(t, "/data/relay.key", c.KeyFile, "next to the database by default")

	c, err = loadConfig(env(map[string]string{"ALLOWED_CLIENT_HOSTS": "claude.ai, Example.COM", "KEY_FILE": "/keys/relay.key"}))
	require.NoError(t, err)
	assert.Equal(t, []string{"claude.ai", "example.com"}, c.AllowedClientHosts.Strings())
	assert.Equal(t, "/keys/relay.key", c.KeyFile)
	c, err = loadConfig(env(map[string]string{"ALLOWED_CLIENT_HOSTS": "*"}))
	require.NoError(t, err)
	assert.Equal(t, []string{"*"}, c.AllowedClientHosts.Strings())

	c, err = loadConfig(env(map[string]string{"TRUSTED_PROXIES": "172.18.0.0/16, 192.0.2.7"}))
	require.NoError(t, err)
	assert.Equal(t, []string{"172.18.0.0/16", "192.0.2.7/32"}, c.TrustedProxies.Strings())
}

// The operator's details for the terms and the privacy policy (FR-193): all optional, but the
// name and the contact come together, and the contact is an email address.
func TestLoadConfigOperator(t *testing.T) {
	c, err := loadConfig(env(nil))
	require.NoError(t, err)
	assert.False(t, c.Operator.Published(), "a relay for oneself needs none of it")

	c, err = loadConfig(env(map[string]string{
		"OPERATOR_NAME": " A Person ", "OPERATOR_CONTACT": "privacy@example.org", "OPERATOR_LAW": "Ruritania",
		"OPERATOR_PROVIDERS": "Example Cloud (hosting)", "BACKUP_DAYS": "14",
	}))
	require.NoError(t, err)
	assert.True(t, c.Operator.Published())
	assert.Equal(t, "A Person", c.Operator.Name)
	assert.Equal(t, "privacy@example.org", c.Operator.Contact)
	assert.Equal(t, "Ruritania", c.Operator.Law)
	assert.Equal(t, "Example Cloud (hosting)", c.Operator.Providers)
	assert.Equal(t, 14, c.Operator.BackupDays)
}

func TestLoadConfigRejects(t *testing.T) {
	cases := map[string]map[string]string{
		"operator name without contact": {"OPERATOR_NAME": "A Person"},
		"operator contact without name": {"OPERATOR_CONTACT": "privacy@example.org"},
		"operator contact not an email": {"OPERATOR_NAME": "A Person", "OPERATOR_CONTACT": "ask at the front desk"},
		"backup days not a number":      {"BACKUP_DAYS": "two weeks"},
		"backup days zero":              {"BACKUP_DAYS": "0"},
		"missing PUBLIC_URL":            {"PUBLIC_URL": ""},
		"relative PUBLIC_URL":           {"PUBLIC_URL": "relay.example.com"},
		"plain http public":             {"PUBLIC_URL": "http://relay.example.com"},
		"PUBLIC_URL with path":          {"PUBLIC_URL": "https://relay.example.com/x"},
		"missing DATA_DIR":              {"DATA_DIR": ""},
		"missing SMTP_HOST":             {"SMTP_HOST": ""},
		"bad SMTP_PORT":                 {"SMTP_PORT": "smtp"},
		"missing SMTP_FROM":             {"SMTP_FROM": ""},
		"user without password":         {"SMTP_USER": "u"},
		"password without user":         {"SMTP_PASSWORD": "p"},
		"bad PORT":                      {"PORT": "http"},
		"bad TRUSTED_PROXIES":           {"TRUSTED_PROXIES": "caddy"},
		"client host with URL":          {"ALLOWED_CLIENT_HOSTS": "https://claude.ai"},
		"client host wildcard":          {"ALLOWED_CLIENT_HOSTS": "*.claude.ai"},
		"star with a host":              {"ALLOWED_CLIENT_HOSTS": "*,claude.ai"},
		"only separators":               {"ALLOWED_CLIENT_HOSTS": " , "},
	}
	for name, o := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := loadConfig(env(o))
			require.Error(t, err)
		})
	}
}

func TestLoadConfigAllowsLoopbackHTTP(t *testing.T) {
	for _, u := range []string{"http://localhost:8080", "http://127.0.0.1:8080"} {
		_, err := loadConfig(env(map[string]string{"PUBLIC_URL": u}))
		require.NoError(t, err, u)
	}
}
