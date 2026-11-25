package reportlog

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestKeepsAccountLinesAndPassesAllOn(t *testing.T) {
	now := time.Date(2026, 11, 25, 3, 0, 0, 0, time.UTC)
	r := New(func() time.Time { return now })
	var out bytes.Buffer
	log := slog.New(r.Wrap(slog.NewTextHandler(&out, nil)))
	log.Warn("report not delivered", "user", "u1", "status", 503)
	log.Info("started", "port", 8080)
	log.With("user", "u2").Error("queue report", "err", "disk full")
	if !strings.Contains(out.String(), "report not delivered") || !strings.Contains(out.String(), "started") {
		t.Fatalf("every line goes on to the relay's log: %s", out.String())
	}
	l1 := r.Lines("u1", time.Time{})
	if len(l1) != 1 || l1[0].Text != "WARN report not delivered status=503" {
		t.Fatalf("u1 = %+v", l1)
	}
	if l2 := r.Lines("u2", time.Time{}); len(l2) != 1 || !strings.Contains(l2[0].Text, "disk full") || strings.Contains(l2[0].Text, "u2") {
		t.Fatalf("u2 = %+v (the account itself is left out of the line)", l2)
	}
	if len(r.Lines("nobody", time.Time{})) != 0 {
		t.Fatal("lines without an account are kept for none")
	}
}

func TestRingIsBounded(t *testing.T) {
	now := time.Date(2026, 11, 25, 3, 0, 0, 0, time.UTC)
	r := New(func() time.Time { return now })
	log := slog.New(r.Wrap(slog.DiscardHandler))
	for i := range PerAccount + 50 {
		log.Info("line", "user", "u1", "i", i)
	}
	ls := r.Lines("u1", time.Time{})
	if len(ls) != PerAccount || !strings.HasSuffix(ls[len(ls)-1].Text, "i=549") {
		t.Fatalf("kept %d, last %q", len(ls), ls[len(ls)-1].Text)
	}
	now = now.Add(MaxAge + time.Minute)
	if len(r.Lines("u1", time.Time{})) != 0 {
		t.Fatal("lines older than a day are forgotten")
	}
}
