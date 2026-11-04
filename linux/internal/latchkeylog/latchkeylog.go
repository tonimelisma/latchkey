// Package latchkeylog is the server's `latchkey_log` tool (spec 010 FR-1052 to FR-1056, plan
// D15): Latchkey's own recent log lines for Claude, with the same arguments and answer as the
// Mac's (spec 001 contracts/mcp-surface.md). Only the activity log's events recorded with public
// words: never Claude's calls, never the relay's address, paths, or call IDs.
package latchkeylog

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/linux/internal/tools"
)

const (
	// Name is the tool's name, the same as the Mac's.
	Name         = "latchkey_log"
	defaultLines = 200
	maxLines     = activity.MaxRecent
	// maxLineCharacters cuts one line; events are a sentence, so this only guards the answer.
	maxLineCharacters = 2000
	// room is what the lines may take of one answer (the Mac's ResultLimit less the header).
	room = 40000 - 600
)

// Categories are the kinds of event Claude can ask for.
var Categories = []string{"app", "connection", "pairing", "settings", "pause", "update", "audit"}

// Tool is the tool for the service: times in the server's own zone.
func Tool(log *activity.Log, path, version string) tools.Tool {
	return New(log, path, version, time.Local)
}

// New is the tool reading the activity log at path, with log's memory when that can't be read.
func New(log *activity.Log, path, version string, zone *time.Location) tools.Tool {
	return tools.Tool{
		Def: tools.Make(tools.Spec{
			Name: Name, Title: "Latchkey's Log",
			Description: fmt.Sprintf("Latchkey's own recent log on this server, for finding out why something in "+
				"Latchkey isn't working: its connection to the relay, pairing, settings, pause, updates, and the "+
				"audit check. Newest last, one line each: time, category, ERROR when it was one, text. It holds "+
				"no tool calls, commands, file names, or the relay's address. Optional: lines (default %d, up "+
				"to %d) and category (one kind only).", defaultLines, maxLines),
			Input: map[string]any{
				"lines":    tools.Integer(fmt.Sprintf("How many of the newest lines (default %d, up to %d)", defaultLines, maxLines)),
				"category": tools.Enum(Categories, "Only lines of this kind"),
			},
			ReadOnly: true, DeadlineMS: 10000,
		}),
		Run: func(_ context.Context, args tools.Args) tools.Result {
			return answer(args, log, path, version, zone)
		},
	}
}

func answer(args tools.Args, log *activity.Log, path, version string, zone *time.Location) tools.Result {
	count, err := args.Int("lines", defaultLines, 1, maxLines)
	if err != nil {
		return tools.Failf("lines must be a whole number from 1 to %d.", maxLines)
	}
	category := ""
	if v, given := args["category"]; given && v != nil {
		s, isString := v.(string)
		switch {
		case !isString:
			return tools.Failf("category must be one of: %s.", strings.Join(Categories, ", "))
		case !contains(Categories, s):
			return tools.Failf("category must be one of: %s (got %q).", strings.Join(Categories, ", "), s)
		}
		category = s
	}
	var note string
	found, err := activity.Public(path, category, count)
	if err != nil {
		note = fmt.Sprintf("Latchkey's activity log isn't available just now (%s), so these are only the lines since Latchkey started.", why(err))
		found = log.Recent(category, count)
	}
	kind := ""
	if category != "" {
		kind = category + " "
	}
	if len(found) == 0 {
		return tools.Text(strings.TrimSpace("Latchkey's log on this server has no " + kind + "lines yet. " + note))
	}
	// Newest first, as many as fit in one answer, then oldest first.
	var lines []string
	used := 0
	for i := len(found) - 1; i >= 0; i-- {
		l := line(found[i], zone)
		n := len([]rune(l)) + 1
		if used+n > room {
			break
		}
		lines = append(lines, l)
		used += n
	}
	left := len(found) - len(lines)
	newest := found[len(found)-1].At.In(zone)
	head := fmt.Sprintf("Latchkey's own %slog on this server (Latchkey %s): the newest %d lines, newest last; times in %s (%s).",
		kind, version, len(lines), ZoneName(zone, os.Getenv("TZ"), localtimeTarget()), offset(newest))
	if note != "" {
		head += " " + note
	}
	var b strings.Builder
	b.WriteString(head)
	for i := len(lines) - 1; i >= 0; i-- {
		b.WriteString("\n" + lines[i])
	}
	if left > 0 {
		fmt.Fprintf(&b, "\n%d older lines left out to keep the answer short; ask for fewer lines or one category.", left)
	}
	return tools.Text(b.String())
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// why says in words why the log couldn't be read, naming no file (FR-1053).
func why(err error) string {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "it isn't there"
	case errors.Is(err, fs.ErrPermission):
		return "permission denied"
	}
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	return "it couldn't be read"
}

func line(e activity.Entry, zone *time.Location) string {
	text := strings.Join(strings.FieldsFunc(e.Public, func(r rune) bool { return r == '\n' || r == '\r' }), " ")
	if r := []rune(text); len(r) > maxLineCharacters {
		text = string(r[:maxLineCharacters]) + "…"
	}
	errMark := ""
	if e.IsError {
		errMark = " ERROR"
	}
	return fmt.Sprintf("%s %s%s: %s", e.At.In(zone).Format("2006-01-02 15:04:05"), e.Category, errMark, text)
}

// offset is "UTC-08:00" for the zone at t.
func offset(t time.Time) string {
	_, seconds := t.Zone()
	sign := "+"
	if seconds < 0 {
		sign, seconds = "-", -seconds
	}
	return fmt.Sprintf("UTC%s%02d:%02d", sign, seconds/3600, seconds/60%60)
}

// ZoneName names the zone: its own name when it has one; for the system's zone, TZ, else the
// zone file /etc/localtime points to, else its abbreviation.
func ZoneName(zone *time.Location, tz, localtime string) string {
	if zone != time.Local && zone.String() != "Local" {
		return zone.String()
	}
	if tz = strings.TrimPrefix(tz, ":"); tz != "" {
		return tz
	}
	if _, name, ok := strings.Cut(localtime, "zoneinfo/"); ok && name != "" {
		return name
	}
	abbr, _ := time.Now().In(zone).Zone()
	return abbr
}

func localtimeTarget() string {
	target, err := os.Readlink("/etc/localtime")
	if err != nil {
		return ""
	}
	return target
}
