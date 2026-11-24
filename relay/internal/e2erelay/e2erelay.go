// Package e2erelay starts a private relay for an end-to-end check and talks to it with a real MCP
// client (spec 015). Apart from internal/e2e, which the relay's own tests import.
package e2erelay

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/oauth"
	"github.com/tonimelisma/latchkey/relay/internal/server"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Private is a relay started for one check (spec 015): its own database, mail kept in memory,
// any client allowed (the check registers its own).
type Private struct {
	Base   string
	DB     *store.Store
	Mail   *account.MemoryMailer
	Server *server.Relay
	srv    *http.Server
}

// PrivateOptions say where the relay keeps its database and answers.
type PrivateOptions struct {
	DBPath string
	// Listen is the address to listen on; empty: a free port on 127.0.0.1.
	Listen string
	// PublicURL is the relay's own address; empty: http://localhost:<port>.
	PublicURL string
	// CertFile and KeyFile serve TLS (the test Mac's relay, spec 015 research.md decision 4a).
	CertFile, KeyFile string
}

// StartPrivate starts a relay for a check; Close stops it.
func StartPrivate(ctx context.Context, o PrivateOptions) (*Private, error) {
	db, err := store.Open(ctx, o.DBPath)
	if err != nil {
		return nil, err
	}
	addr := o.Listen
	if addr == "" {
		addr = "127.0.0.1:0"
	}
	l, err := (&net.ListenConfig{}).Listen(ctx, "tcp", addr)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	base := o.PublicURL
	if base == "" {
		base = fmt.Sprintf("http://localhost:%d", l.Addr().(*net.TCPAddr).Port)
	}
	public, err := url.Parse(base)
	if err != nil {
		_ = l.Close()
		_ = db.Close()
		return nil, err
	}
	mail := &account.MemoryMailer{}
	r, err := server.New(ctx, server.Options{
		PublicURL: public, Store: db, Mailer: mail,
		AllowedClients: oauth.AnyClientHost(), // the check registers its own throwaway client
		Logger:         slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		_ = l.Close()
		_ = db.Close()
		return nil, err
	}
	p := &Private{
		Base: base, DB: db, Mail: mail, Server: r,
		srv: &http.Server{Handler: r.Handler, ReadHeaderTimeout: 10 * time.Second},
	}
	go func() {
		if o.CertFile != "" {
			_ = p.srv.ServeTLS(l, o.CertFile, o.KeyFile)
		} else {
			_ = p.srv.Serve(l)
		}
	}()
	return p, nil
}

// Close stops the relay and closes its database.
func (p *Private) Close() {
	p.Server.Hub.Close()
	_ = p.srv.Close()
	_ = p.DB.Close()
}

var sixDigits = regexp.MustCompile(`\b\d{6}\b`)

// CodeFor returns the sign-in code the relay last emailed to an address.
func (p *Private) CodeFor(email string) (string, error) {
	sent := p.Mail.Sent()
	for i := len(sent) - 1; i >= 0; i-- {
		if sent[i].To == email {
			return sixDigits.FindString(sent[i].Body), nil
		}
	}
	return "", errors.New("no email to " + email)
}

// NewestDevice returns the account's newest active pairing.
func (p *Private) NewestDevice(ctx context.Context, email string) (string, error) {
	u, err := p.DB.UserByEmail(ctx, email)
	if err != nil {
		return "", err
	}
	devices, err := p.DB.ActiveDevices(ctx, u.ID)
	if err != nil || len(devices) == 0 {
		return "", errors.Join(err, store.ErrNotFound)
	}
	return devices[len(devices)-1].ID, nil
}

// WaitOnline waits until the account's newest machine is connected.
func (p *Private) WaitOnline(ctx context.Context, email string, within time.Duration) error {
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		if d, err := p.NewestDevice(ctx, email); err == nil && p.Server.Hub.Online(d) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	return fmt.Errorf("the machine never connected within %s", within)
}

type bearer struct{ token string }

func (b bearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+b.token)
	return http.DefaultTransport.RoundTrip(r)
}

// MCPClient connects a real MCP client to the relay with an access token.
func MCPClient(ctx context.Context, base, token, name string) (*mcp.ClientSession, error) {
	c := mcp.NewClient(&mcp.Implementation{Name: name, Version: "1"}, nil)
	return c.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint: base + "/mcp", HTTPClient: &http.Client{Transport: bearer{token}}, MaxRetries: -1,
	}, &mcp.ClientSessionOptions{ProtocolVersion: "2025-11-25"})
}

// TextOf joins a tool result's text.
func TextOf(res *mcp.CallToolResult) string {
	var parts []string
	for _, c := range res.Content {
		if t, ok := c.(*mcp.TextContent); ok {
			parts = append(parts, t.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// ListAllTools lists every tool, page by page.
func ListAllTools(ctx context.Context, cs *mcp.ClientSession) ([]*mcp.Tool, error) {
	var out []*mcp.Tool
	for t, err := range cs.Tools(ctx, nil) {
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, nil
}
