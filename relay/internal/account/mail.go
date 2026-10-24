package account

import (
	"context"
	"fmt"
	"net/netip"
	"sync"
	"time"

	"github.com/wneessen/go-mail"
)

// Mailer sends plain-text email.
type Mailer interface {
	Send(ctx context.Context, to, subject, body string) error
}

// SMTPConfig is the relay's outgoing mail server (plan D5, FR-080).
type SMTPConfig struct {
	Host     string
	Port     int
	User     string // empty: no authentication
	Password string
	From     string
}

// SMTPMailer sends through an SMTP server, always encrypted: TLS from the start on port 465,
// STARTTLS on any other port, and a server that doesn't offer STARTTLS gets nothing. Only a
// server on this machine (a local test mail catcher) may be reached without encryption.
type SMTPMailer struct {
	cfg  SMTPConfig
	dial mail.DialContextFunc // tests only: connect somewhere else
}

// NewSMTPMailer returns a mailer for cfg.
func NewSMTPMailer(cfg SMTPConfig) *SMTPMailer { return &SMTPMailer{cfg: cfg} }

// Send delivers one message, giving up after 15 seconds.
func (m *SMTPMailer) Send(ctx context.Context, to, subject, body string) error {
	msg := mail.NewMsg()
	if err := msg.From(m.cfg.From); err != nil {
		return fmt.Errorf("from address: %w", err)
	}
	if err := msg.To(to); err != nil {
		return fmt.Errorf("to address: %w", err)
	}
	msg.Subject(subject)
	msg.SetBodyString(mail.TypeTextPlain, body)
	// Mandatory: an on-path attacker who strips STARTTLS would otherwise read the sign-in and
	// recovery codes (security scan, 2026-10-24).
	policy := mail.TLSMandatory
	if plainSMTPAllowed(m.cfg.Host) {
		policy = mail.TLSOpportunistic
	}
	opts := []mail.Option{mail.WithPort(m.cfg.Port), mail.WithTLSPolicy(policy), mail.WithTimeout(15 * time.Second)}
	if m.cfg.Port == 465 {
		opts = append(opts, mail.WithSSL())
	}
	if m.cfg.User != "" {
		opts = append(opts, mail.WithSMTPAuth(mail.SMTPAuthAutoDiscover), mail.WithUsername(m.cfg.User), mail.WithPassword(m.cfg.Password))
	}
	if m.dial != nil {
		opts = append(opts, mail.WithDialContextFunc(m.dial))
	}
	c, err := mail.NewClient(m.cfg.Host, opts...)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	return c.DialAndSendWithContext(ctx, msg)
}

// MemoryMailer keeps messages instead of sending them; for tests and local development.
type MemoryMailer struct {
	mu   sync.Mutex
	sent []Message
}

// Message is a sent email.
type Message struct{ To, Subject, Body string }

// Send records the message.
func (m *MemoryMailer) Send(_ context.Context, to, subject, body string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent = append(m.sent, Message{to, subject, body})
	return nil
}

// Sent returns a copy of all messages so far.
func (m *MemoryMailer) Sent() []Message {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Message(nil), m.sent...)
}

// plainSMTPAllowed reports whether host is this machine, the only place mail may go unencrypted.
func plainSMTPAllowed(host string) bool {
	if host == "localhost" {
		return true
	}
	a, err := netip.ParseAddr(host)
	return err == nil && a.Unmap().IsLoopback()
}
