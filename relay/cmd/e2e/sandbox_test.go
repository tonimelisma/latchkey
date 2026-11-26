package main

import (
	"context"
	"errors"
	"io"
	"net"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSelectChecks(t *testing.T) {
	all, err := selectChecks("")
	if err != nil || !slices.Equal(all, sandboxOrder) {
		t.Fatalf("empty: %v %v", all, err)
	}
	if got, _ := selectChecks("all"); !slices.Equal(got, sandboxOrder) {
		t.Fatalf("all: %v", got)
	}
	got, err := selectChecks("suspended, files,notes")
	if err != nil || !slices.Equal(got, []string{"files", "notes", "suspended"}) {
		t.Fatalf("a few, in run order: %v %v", got, err)
	}
	if _, err := selectChecks("files,nope"); err == nil || !strings.Contains(err.Error(), `unknown check "nope"`) {
		t.Fatalf("unknown: %v", err)
	}
	if _, err := selectChecks(" , "); err == nil {
		t.Fatal("no names: want an error")
	}
}

// Every check is either run or skipped with its reason, never both, never neither.
func TestEveryCheckRunsOrIsSkipped(t *testing.T) {
	funcs := (&sandbox{}).checkFuncs()
	for _, n := range sandboxOrder {
		_, runs := funcs[n]
		why, skips := sandboxSkips[n]
		if runs == skips {
			t.Errorf("%s: runs %v, skipped %v", n, runs, skips)
		}
		if skips && why == "" {
			t.Errorf("%s: skipped without a reason", n)
		}
	}
	for n := range funcs {
		if !slices.Contains(sandboxOrder, n) {
			t.Errorf("%s runs but isn't in sandboxOrder", n)
		}
	}
	for n := range sandboxSkips {
		if !slices.Contains(sandboxOrder, n) {
			t.Errorf("%s is skipped but isn't in sandboxOrder", n)
		}
	}
	// The checks moved from cmd/maccheck (spec 016 plan D2) are all here.
	for _, n := range []string{"turned-off", "offline", "relay-restart", "network-cut", "suspended", "battery", "pair-preview"} {
		if !slices.Contains(sandboxOrder, n) {
			t.Errorf("maccheck's %s check is missing", n)
		}
	}
}

func TestSummaryLine(t *testing.T) {
	for _, c := range []struct {
		in   sandboxCheck
		want string
	}{
		{sandboxCheck{Name: "files", Result: "passed", Seconds: 3.24}, "PASS files (3.2 s)"},
		{sandboxCheck{Name: "notes", Result: "failed", Seconds: 1, Why: "no note"}, "FAIL notes (1.0 s): no note"},
		{sandboxCheck{Name: "mail", Result: "skipped", Why: "no account"}, "SKIP mail: no account"},
	} {
		if got := summaryLine(c.in); got != c.want {
			t.Errorf("%+v: %q, want %q", c.in, got, c.want)
		}
	}
	r := sandboxResult{Checks: []sandboxCheck{{Result: "passed"}, {Result: "failed"}, {Result: "skipped"}, {Result: "failed"}}}
	if r.failed() != 2 {
		t.Errorf("failed() = %d, want 2", r.failed())
	}
}

// idOn reads the ids in the answers' own formats (NotesCapability, CalendarCapability,
// RemindersCapability, ContactsCapability).
func TestIDOn(t *testing.T) {
	for _, c := range []struct{ answer, label, want string }{
		{"Notes:\n- Shopping list (id x-coredata://AB-12/ICNote/p7; folder LatchkeyEval; changed 2026-11-26T10:00:00Z)", "Shopping list", "x-coredata://AB-12/ICNote/p7"},
		{`Created “Sandbox ab12” (id x-coredata://AB/ICNote/p9).`, "Sandbox ab12", "x-coredata://AB/ICNote/p9"},
		{"- Pay rent (id R1)\n- Buy stamps (id 5F3E-77)", "Buy stamps", "5F3E-77"},
		{"Jordan Evaltest · LatchkeyEval (id 4C2D:ABPerson)", "Jordan", "4C2D:ABPerson"},
		{"Added Jordan Evaltest to Contacts. id 4C2D:ABPerson", "Jordan", "4C2D:ABPerson"},
		{"title: Buy stamps\nid: R2", "id:", "R2"},
		{"- Something else (id Z)", "Buy stamps", ""},
	} {
		if got := idOn(c.answer, c.label); got != c.want {
			t.Errorf("idOn(%q, %q) = %q, want %q", c.answer, c.label, got, c.want)
		}
	}
}

// The checks inside the test Mac look for the name prepare paired it under; they looked for
// "E2E Mac" (the GitHub runner's name), so the evals' tool check could never pass.
func TestTestMacChecksLookForTheImagesMachineName(t *testing.T) {
	if m := vmMacCheck(context.Background(), nil); m.machine != testMacName || testMacName == e2eMacName {
		t.Fatalf("vmMacCheck machine %q, want %q (not %q)", m.machine, testMacName, e2eMacName)
	}
}

func TestBatteryMismatch(t *testing.T) {
	line := func(p int) string {
		return "hi\nTest Mac (Mac): online · " + strconv.Itoa(p) + "% battery, charging · keep-awake on"
	}
	const vm = "Now drawing from 'AC Power'\n"
	const laptop = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)	64%; discharging; 3:10 remaining present: true\n"
	for _, c := range []struct {
		answer, pmset string
		ok            bool
	}{
		{line(64), laptop, true},
		{line(65), laptop, true},
		{line(70), laptop, false},
		{"hi\nTest Mac (Mac): online", laptop, false},
		{line(0), vm, true},
		{"hi\nTest Mac (Mac): online", vm, true},
		{line(82), vm, false}, // a made-up percent
	} {
		if got := batteryMismatch(c.answer, c.pmset); (got == "") != c.ok {
			t.Errorf("answer %q, pmset %q: %q", c.answer, c.pmset, got)
		}
	}
}

// echoServer answers every connection with what it receives.
func echoServer(t *testing.T) (string, func()) {
	t.Helper()
	l, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() { _, _ = io.Copy(c, c); _ = c.Close() }()
		}
	}()
	return l.Addr().String(), func() { _ = l.Close() }
}

func roundTrip(c net.Conn, msg string, within time.Duration) (string, error) {
	_ = c.SetDeadline(time.Now().Add(within))
	if _, err := c.Write([]byte(msg)); err != nil {
		return "", err
	}
	buf := make([]byte, len(msg))
	_, err := io.ReadFull(c, buf)
	return string(buf), err
}

func TestCutProxy(t *testing.T) {
	target, stop := echoServer(t)
	defer stop()
	p, err := newCutProxy(t.Context(), "127.0.0.1:0", target)
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	dial := func() net.Conn {
		c, err := (&net.Dialer{}).DialContext(t.Context(), "tcp", p.addr())
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	c := dial()
	if got, err := roundTrip(c, "hello", 2*time.Second); err != nil || got != "hello" {
		t.Fatalf("forwarded: %q %v", got, err)
	}
	p.blackhole()
	if got, err := roundTrip(c, "lost", 300*time.Millisecond); err == nil {
		t.Fatalf("while cut, %q came back", got)
	}
	cut := dial()
	if _, err := roundTrip(cut, "new", 300*time.Millisecond); err == nil {
		t.Fatal("while cut, a new connection was answered")
	}
	p.restore()
	_ = c.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("a connection from before the cut still works after restore")
	}
	c2 := dial()
	defer func() { _ = c2.Close() }()
	if got, err := roundTrip(c2, "again", 2*time.Second); err != nil || got != "again" {
		t.Fatalf("after restore: %q %v", got, err)
	}
}

// When the far side goes away (the relay restarts), the near side sees it at once, not only at
// its heartbeat's deadline.
func TestCutProxyPassesOnAClose(t *testing.T) {
	l, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = l.Close() }()
	go func() {
		c, err := l.Accept()
		if err == nil {
			_ = c.Close() // the relay leaves
		}
	}()
	p, err := newCutProxy(t.Context(), "127.0.0.1:0", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	c, err := (&net.Dialer{}).DialContext(t.Context(), "tcp", p.addr())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, err = c.Read(make([]byte, 1))
	if err == nil {
		t.Fatal("read data from a closed far side")
	}
	if ne, ok := errors.AsType[net.Error](err); ok && ne.Timeout() {
		t.Fatal("the far side's close never reached the near side")
	}
}
