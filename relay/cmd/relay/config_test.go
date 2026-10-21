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

func TestLoadConfig(t *testing.T) {
	c, err := loadConfig(env(map[string]string{"SMTP_USER": "u", "SMTP_PASSWORD": "p", "ACME_EMAIL": "a@example.com"}))
	require.NoError(t, err)
	assert.Equal(t, "https://relay.example.com", c.PublicURL.String())
	assert.Equal(t, "/data", c.DataDir)
	assert.Equal(t, 587, c.SMTPPort)
	assert.Equal(t, "u", c.SMTPUser)
	assert.Equal(t, "a@example.com", c.ACMEEmail)
}

func TestLoadConfigRejects(t *testing.T) {
	cases := map[string]map[string]string{
		"missing PUBLIC_URL":    {"PUBLIC_URL": ""},
		"relative PUBLIC_URL":   {"PUBLIC_URL": "relay.example.com"},
		"plain http public":     {"PUBLIC_URL": "http://relay.example.com"},
		"PUBLIC_URL with path":  {"PUBLIC_URL": "https://relay.example.com/x"},
		"missing DATA_DIR":      {"DATA_DIR": ""},
		"missing SMTP_HOST":     {"SMTP_HOST": ""},
		"bad SMTP_PORT":         {"SMTP_PORT": "smtp"},
		"missing SMTP_FROM":     {"SMTP_FROM": ""},
		"user without password": {"SMTP_USER": "u"},
		"password without user": {"SMTP_PASSWORD": "p"},
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
