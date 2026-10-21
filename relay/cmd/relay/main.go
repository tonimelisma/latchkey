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

	"github.com/tonimelisma/latchkey/relay/internal/account"
	"github.com/tonimelisma/latchkey/relay/internal/server"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

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

	r, err := server.New(ctx, server.Options{
		PublicURL: cfg.PublicURL, Store: db, AllowedEmails: cfg.AllowedEmails, Logger: logger, Version: version,
		Mailer: account.NewSMTPMailer(account.SMTPConfig{
			Host: cfg.SMTPHost, Port: cfg.SMTPPort, User: cfg.SMTPUser, Password: cfg.SMTPPassword, From: cfg.SMTPFrom,
		}),
	})
	if err != nil {
		return err
	}

	srv := &http.Server{
		Addr:              ":" + strconv.Itoa(cfg.Port), // all interfaces, IPv4 and IPv6 (plan D10)
		Handler:           r.Handler,
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

	go server.Purge(ctx, db, logger)

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
	r.Hub.Close()
	if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
