package shell

import (
	"regexp"
	"strings"
	"sync"
)

// maxKept is how much of a job's output is kept in memory; maxShown how much of it an answer
// shows (the most recent part, FR-305).
const (
	maxKept  = 512 << 10
	maxShown = 20_000
)

// sudoPrompt is what sudo writes when it waits for a password at the terminal (a sudo the wrapper
// didn't catch, such as /usr/bin/sudo by its full path).
var sudoPrompt = regexp.MustCompile(`\[sudo\] password for [^:\n]*:`)

// sudoRefused is what sudo -n writes when a password would be needed.
const sudoRefused = "sudo: a password is required"

// SudoHint is told to Claude whenever sudo would need a password (FR-1031).
const SudoHint = "sudo needs a password on this server, and Latchkey never types one. The server's owner can allow passwordless sudo " +
	"(NOPASSWD in /etc/sudoers.d) for the commands Claude should run."

// buffer is a job's output: what the terminal printed, the newest maxKept bytes of it.
type buffer struct {
	mu      sync.Mutex
	data    []byte
	dropped int // bytes dropped from the front
	checked int // absolute offset Claude has seen up to
	prompt  bool
	refused bool
	notify  func() // called when sudo's prompt appears
}

func (b *buffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	b.data = append(b.data, p...)
	if over := len(b.data) - maxKept; over > 0 {
		b.data = append([]byte(nil), b.data[over:]...)
		b.dropped += over
	}
	tail := string(b.data[max(0, len(b.data)-len(p)-64):])
	newPrompt := !b.prompt && sudoPrompt.MatchString(tail)
	b.prompt = b.prompt || newPrompt
	b.refused = b.refused || strings.Contains(tail, sudoRefused)
	notify := b.notify
	b.mu.Unlock()
	if newPrompt && notify != nil {
		notify()
	}
	return len(p), nil
}

// since returns the output after the absolute offset from (cleaned for reading), whether some of
// it was dropped, and the new end offset.
func (b *buffer) since(from int) (string, bool, int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	end := b.dropped + len(b.data)
	lost := from < b.dropped
	start := max(from, b.dropped) - b.dropped
	return clean(string(b.data[start:])), lost, end
}

// unseen returns what Claude hasn't seen yet and marks it seen.
func (b *buffer) unseen() (string, bool) {
	b.mu.Lock()
	from := b.checked
	b.mu.Unlock()
	text, lost, end := b.since(from)
	b.mu.Lock()
	b.checked = end
	b.mu.Unlock()
	return text, lost
}

func (b *buffer) sudo() (prompt, refused bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.prompt, b.refused
}

var (
	// Terminal control sequences: CSI (colours, cursor), OSC (titles, ended by BEL or ST), and
	// two-byte escapes.
	escapes = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-Z\\-_]`)
	// Other control characters except tab and line breaks.
	controls = regexp.MustCompile(`[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]`)
)

// clean removes terminal control codes (FR-304) and keeps, of a line rewritten with carriage
// returns (a progress bar), what it ended as.
func clean(s string) string {
	s = escapes.ReplaceAllString(s, "")
	s = strings.ReplaceAll(s, "\r\n", "\n")
	lines := strings.Split(s, "\n")
	for i, line := range lines {
		if j := strings.LastIndex(strings.TrimRight(line, "\r"), "\r"); j >= 0 {
			line = line[j+1:]
		}
		lines[i] = strings.TrimRight(line, "\r")
	}
	return controls.ReplaceAllString(strings.Join(lines, "\n"), "")
}

// tail keeps the most recent maxShown characters.
func tail(s string) (string, bool) {
	r := []rune(s)
	if len(r) <= maxShown {
		return s, false
	}
	return string(r[len(r)-maxShown:]), true
}
