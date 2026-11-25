// latchkey-intake is the developer's intake for problem reports (spec 014): it takes the reports
// relays send, sealed to the developer's key, and gives them to the developer. It never holds a
// key that opens them.
//
// Settings (environment): DEVELOPER_TOKEN (32 characters or more; or DEVELOPER_TOKEN_FILE),
// DATA_DIR (default /data), PORT (default 8080), PER_HOUR (reports per sender address, default
// 60), TRUSTED_PROXIES (the reverse proxy in front, as for the relay). `latchkey-intake
// healthcheck` checks a running intake, for the container's health check.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/intake"
	"github.com/tonimelisma/latchkey/relay/internal/limit"
)

var version = "dev"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "latchkey-intake:", err)
		os.Exit(1)
	}
}

func port() string {
	if p, err := strconv.Atoi(os.Getenv("PORT")); err == nil && p > 0 && p < 65536 {
		return strconv.Itoa(p)
	}
	return "8080"
}

func healthcheck() int {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://127.0.0.1:"+port()+"/healthz", nil)
	if err != nil {
		return 1
	}
	resp, err := (&http.Client{}).Do(req) //nolint:gosec // loopback probe of this process, numeric port
	if err != nil {
		return 1
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func run() error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	token := strings.TrimSpace(os.Getenv("DEVELOPER_TOKEN"))
	if f := os.Getenv("DEVELOPER_TOKEN_FILE"); token == "" && f != "" {
		b, err := os.ReadFile(f) //nolint:gosec // the operator's own setting names the file
		if err != nil {
			return err
		}
		token = strings.TrimSpace(string(b))
	}
	if token == "" {
		return errors.New("DEVELOPER_TOKEN or DEVELOPER_TOKEN_FILE is required")
	}
	dir := os.Getenv("DATA_DIR")
	if dir == "" {
		dir = "/data"
	}
	perHour := 60
	if v := os.Getenv("PER_HOUR"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			return errors.New("PER_HOUR must be a number, 1 or more")
		}
		perHour = n
	}
	proxies, err := limit.ParseTrustedProxies(os.Getenv("TRUSTED_PROXIES"))
	if err != nil {
		return fmt.Errorf("TRUSTED_PROXIES: %w", err)
	}
	in, err := intake.Open(filepath.Join(dir, "intake.db"), intake.Options{
		DeveloperToken: token, PerHour: perHour, TrustedProxies: proxies, Logger: logger,
	})
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	srv := &http.Server{
		Addr: ":" + port(), Handler: in.Handler(),
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: time.Minute, WriteTimeout: time.Minute, // 5 MB reports (FR-1455)
		IdleTimeout: time.Minute, MaxHeaderBytes: 16 << 10,
	}
	errc := make(chan error, 1)
	go func() {
		waiting, _ := in.Waiting(ctx)
		logger.Info("intake listening", "port", port(), "waiting", waiting, "version", version)
		errc <- srv.ListenAndServe()
	}()
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shut)
}
