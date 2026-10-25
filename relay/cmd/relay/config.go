package main

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/limit"
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
	// Operator is who runs this relay, for its terms and privacy policy (FR-193): OPERATOR_NAME,
	// OPERATOR_CONTACT, OPERATOR_LAW, OPERATOR_PROVIDERS, BACKUP_DAYS.
	Operator account.Operator
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
	c.Operator = account.Operator{
		Name: strings.TrimSpace(getenv("OPERATOR_NAME")), Contact: strings.TrimSpace(getenv("OPERATOR_CONTACT")),
		Law: strings.TrimSpace(getenv("OPERATOR_LAW")), Providers: strings.TrimSpace(getenv("OPERATOR_PROVIDERS")),
	}
	if d := strings.TrimSpace(getenv("BACKUP_DAYS")); d != "" {
		if c.Operator.BackupDays, err = strconv.Atoi(d); err != nil || c.Operator.BackupDays <= 0 {
			errs = append(errs, errors.New("BACKUP_DAYS must be a number of days, 1 or more"))
			c.Operator.BackupDays = 0
		}
	}
	if err := c.Operator.Validate(); err != nil {
		errs = append(errs, err)
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
