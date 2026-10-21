// Command relay is the Latchkey relay: the MCP server Claude connects to and the hub the Mac app
// dials into.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"golang.org/x/crypto/acme/autocert"

	"github.com/tonimelisma/latchkey/relay/internal/hub"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

const auditRetention = 30 * 24 * time.Hour // FR-024

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx)
	stop()
	if err != nil {
		fmt.Fprintln(os.Stderr, "relay:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	cfg, err := loadConfig(os.Getenv)
	if err != nil {
		return err
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	slog.SetDefault(logger)

	db, err := store.Open(ctx, filepath.Join(cfg.DataDir, "relay.db"))
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()

	var ms *mcpserver.Server
	h := hub.New(db, hub.Config{
		Logger:         logger,
		OnToolsChanged: func(userID string) { ms.ToolsChanged(userID) },
	})
	ms = mcpserver.New(db, h, mcpserver.Options{Logger: logger, Version: version})

	mux := http.NewServeMux()
	mux.Handle("GET /agent/v1", h)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	// /mcp, OAuth, and account pages are added with sign-in (tasks T030 to T039).

	srv := &http.Server{
		Addr:              ":" + strconv.Itoa(cfg.Port), // all interfaces, IPv4 and IPv6 (plan D10)
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if cfg.ACMEEmail != "" {
		m := &autocert.Manager{
			Prompt:     autocert.AcceptTOS,
			Email:      cfg.ACMEEmail,
			HostPolicy: autocert.HostWhitelist(cfg.PublicURL.Hostname()),
			Cache:      autocert.DirCache(filepath.Join(cfg.DataDir, "certs")),
		}
		srv.TLSConfig = &tls.Config{GetCertificate: m.GetCertificate, NextProtos: []string{"h2", "http/1.1", "acme-tls/1"}, MinVersion: tls.VersionTLS12}
	}

	go purgeAudit(ctx, db, logger)

	errc := make(chan error, 1)
	go func() {
		logger.Info("relay listening", "port", cfg.Port, "public_url", cfg.PublicURL.String(), "tls", cfg.ACMEEmail != "", "version", version)
		if srv.TLSConfig != nil {
			errc <- srv.ListenAndServeTLS("", "")
		} else {
			errc <- srv.ListenAndServe()
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	logger.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	h.Close()
	if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// purgeAudit deletes audit entries past retention at startup and then daily.
func purgeAudit(ctx context.Context, db *store.Store, logger *slog.Logger) {
	t := time.NewTicker(24 * time.Hour)
	defer t.Stop()
	for {
		n, err := db.PurgeAudit(ctx, time.Now().Add(-auditRetention))
		if err != nil {
			logger.Error("purge audit log", "err", err)
		} else if n > 0 {
			logger.Info("purged audit log", "rows", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
