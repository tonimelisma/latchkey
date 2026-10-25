package main

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// config is the relay's environment configuration (plan D10).
type config struct {
	PublicURL    *url.URL
	DataDir      string
	SMTPHost     string
	SMTPPort     int
	SMTPUser     string
	SMTPPassword string
	SMTPFrom     string
	ACMEEmail    string
	Port         int
	// AllowedEmails limits sign-up (FR-046); empty means open.
	AllowedEmails []string
	// TrustedProxies whose X-Forwarded-For is believed, besides loopback (FR-082).
	TrustedProxies limit.TrustedProxies
	// AllowedClientHosts whose clients may ask for access (FR-180); default claude.ai, "*" any.
	AllowedClientHosts oauth.AllowedHosts
	// KeyFile holds the key the relay's stored signing keys are encrypted under (FR-186).
	KeyFile string
}

func loadConfig(getenv func(string) string) (config, error) {
	c := config{
		DataDir:      getenv("DATA_DIR"),
		SMTPHost:     getenv("SMTP_HOST"),
		SMTPUser:     getenv("SMTP_USER"),
		SMTPPassword: getenv("SMTP_PASSWORD"),
		SMTPFrom:     getenv("SMTP_FROM"),
		ACMEEmail:    getenv("ACME_EMAIL"),
	}
	var errs []error
	u, err := parsePublicURL(getenv("PUBLIC_URL"))
	if err != nil {
		errs = append(errs, err)
	}
	c.PublicURL = u
	for name, v := range map[string]string{"DATA_DIR": c.DataDir, "SMTP_HOST": c.SMTPHost, "SMTP_FROM": c.SMTPFrom} {
		if v == "" {
			errs = append(errs, fmt.Errorf("%s is required", name))
		}
	}
	if c.SMTPPort, err = strconv.Atoi(getenv("SMTP_PORT")); err != nil || c.SMTPPort <= 0 || c.SMTPPort > 65535 {
		errs = append(errs, errors.New("SMTP_PORT must be a port number"))
	}
	c.Port = 8080
	if p := getenv("PORT"); p != "" {
		if c.Port, err = strconv.Atoi(p); err != nil || c.Port <= 0 || c.Port > 65535 {
			errs = append(errs, errors.New("PORT must be a port number"))
		}
	}
	for e := range strings.SplitSeq(getenv("ALLOWED_EMAILS"), ",") {
		if e = strings.TrimSpace(e); e != "" {
			c.AllowedEmails = append(c.AllowedEmails, e)
		}
	}
	if c.TrustedProxies, err = limit.ParseTrustedProxies(getenv("TRUSTED_PROXIES")); err != nil {
		errs = append(errs, fmt.Errorf("TRUSTED_PROXIES: %w", err))
	}
	if (c.SMTPUser == "") != (c.SMTPPassword == "") {
		errs = append(errs, errors.New("SMTP_USER and SMTP_PASSWORD must be set together"))
	}
	if c.AllowedClientHosts, err = oauth.ParseAllowedHosts(getenv("ALLOWED_CLIENT_HOSTS")); err != nil {
		errs = append(errs, fmt.Errorf("ALLOWED_CLIENT_HOSTS: %w", err))
	}
	if c.KeyFile = getenv("KEY_FILE"); c.KeyFile == "" && c.DataDir != "" {
		c.KeyFile = filepath.Join(c.DataDir, store.DefaultKeyFileName)
	}
	return c, errors.Join(errs...)
}

// parsePublicURL accepts an https origin, or an http origin on loopback for local development.
func parsePublicURL(s string) (*url.URL, error) {
	if s == "" {
		return nil, errors.New("PUBLIC_URL is required")
	}
	u, err := url.Parse(s)
	if err != nil || u.Host == "" {
		return nil, fmt.Errorf("PUBLIC_URL %q is not an absolute URL", s)
	}
	if (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return nil, fmt.Errorf("PUBLIC_URL %q must be an origin, without path or query", s)
	}
	switch u.Scheme {
	case "https":
	case "http":
		if ip := net.ParseIP(u.Hostname()); u.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return nil, fmt.Errorf("PUBLIC_URL %q must use https (http only on localhost)", s)
		}
	default:
		return nil, fmt.Errorf("PUBLIC_URL %q must use https", s)
	}
	u.Path = ""
	return u, nil
}
