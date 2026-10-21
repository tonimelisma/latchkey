package account

import (
	"context"
	"fmt"
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

// SMTPMailer sends through an SMTP server, using STARTTLS when the server offers it.
type SMTPMailer struct{ cfg SMTPConfig }

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
	opts := []mail.Option{mail.WithPort(m.cfg.Port), mail.WithTLSPolicy(mail.TLSOpportunistic), mail.WithTimeout(15 * time.Second)}
	if m.cfg.Port == 465 {
		opts = append(opts, mail.WithSSL())
	}
	if m.cfg.User != "" {
		opts = append(opts, mail.WithSMTPAuth(mail.SMTPAuthAutoDiscover), mail.WithUsername(m.cfg.User), mail.WithPassword(m.cfg.Password))
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
