package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/e2erelay"
)

// The per-app checks of the sandbox copy (relay/e2e/sandbox-checks.md, "From state-check"): each
// former use-case group's steps against the real app with test data, each change seen in the app
// itself (AppleScript or the disk, not Latchkey's own answer), and everything a check made, named
// with the run's marker, removed at its end, whatever happened.

// ask calls a tool, fails on a tool error, and wants every one of want in the answer (any case).
func (s *sandbox) ask(tool string, args map[string]any, want ...string) (string, error) {
	t, err := s.m.text(tool, args)
	if err != nil {
		return t, err
	}
	low := strings.ToLower(t)
	for _, w := range want {
		if !strings.Contains(low, strings.ToLower(w)) {
			return t, fmt.Errorf("%s %v: the answer lacks %q: %q", tool, args, w, short(t))
		}
	}
	return t, nil
}

// tag is what every item a check makes is named with, so the clean-up finds it.
func (s *sandbox) tag() string { return "Sandbox " + s.m.marker }

func (s *sandbox) notes() error {
	if err := s.fixture("sweep notes", "fixture notes shopping"); err != nil {
		return err
	}
	tag := s.tag()
	defer func() {
		_ = s.fx.do("sweep notes")
		_ = osa(`on run argv
tell application "Notes"
repeat with f in (every folder whose name starts with (item 1 of argv))
delete f
end repeat
end tell
end run`, tag)
	}()
	if _, err := s.ask("notes_find", map[string]any{}, evalName); err != nil {
		return fmt.Errorf("the folders: %w", err)
	}
	t, err := s.ask("notes_find", map[string]any{"query": "Shopping list", "folder": evalName}, "Shopping list")
	if err != nil {
		return err
	}
	shop := idOn(t, "Shopping list")
	if shop == "" {
		return fmt.Errorf("notes_find gave the shopping list no id: %q", short(t))
	}
	if _, err := s.ask("notes_read", map[string]any{"id": shop}, "eggs", "bread"); err != nil {
		return err
	}
	// create in a folder, append, edit, replace, rename
	t, err = s.ask("notes_change", map[string]any{"action": "create", "folder": evalName, "title": tag, "text": "First line"})
	if err != nil {
		return err
	}
	if err := s.holds("notes", "body-contains", tag, "First line"); err != nil {
		return err
	}
	id := idOn(t, tag)
	if id == "" {
		return fmt.Errorf("notes_change create gave no id: %q", short(t))
	}
	if _, err := s.ask("notes_change", map[string]any{"action": "append", "id": id, "text": "Appended line"}); err != nil {
		return err
	}
	if err := s.holds("notes", "body-contains", tag, "Appended line"); err != nil {
		return err
	}
	if _, err := s.ask("notes_change", map[string]any{"action": "edit", "id": id, "find": "Appended line", "text": "Edited line"}); err != nil {
		return err
	}
	if err := s.holds("notes", "body-contains", tag, "Edited line"); err != nil {
		return err
	}
	if _, err := s.ask("notes_change", map[string]any{"action": "replace", "id": id, "text": "- one\n- two"}); err != nil {
		return err
	}
	if _, err := s.ask("notes_read", map[string]any{"id": id}, "one", "two"); err != nil {
		return err
	}
	if err := s.holds("notes", "body-contains", tag, "two"); err != nil {
		return err
	}
	renamed := tag + " renamed"
	if _, err := s.ask("notes_change", map[string]any{"action": "rename", "id": id, "title": renamed}); err != nil {
		return err
	}
	if _, err := s.ask("notes_read", map[string]any{"id": id}, renamed); err != nil {
		return err
	}
	// folders: make one, move the note there, a new note in a folder that doesn't exist yet
	folder := tag + " folder"
	if _, err := s.ask("notes_change", map[string]any{"action": "create_folder", "folder": folder}); err != nil {
		return err
	}
	if _, err := s.ask("notes_change", map[string]any{"action": "move", "id": id, "folder": folder}); err != nil {
		return err
	}
	if _, err := s.ask("notes_find", map[string]any{"folder": folder}, renamed); err != nil {
		return fmt.Errorf("after the move: %w", err)
	}
	t, err = s.ask("notes_change", map[string]any{"action": "create", "folder": tag + " new folder", "title": tag + " new", "text": "Hi"})
	if err != nil {
		return err
	}
	if low := strings.ToLower(t); !strings.Contains(low, "folder") || !strings.Contains(low, "made") && !strings.Contains(low, "created") && !strings.Contains(low, "new") {
		return fmt.Errorf("a note in a new folder: the answer doesn't say the folder was made: %q", short(t))
	}
	// a checklist reads back as - [ ] and - [x]
	t, err = s.ask("notes_change", map[string]any{"action": "create", "folder": evalName, "title": tag + " list", "text": "- [ ] eggs\n- [x] milk"})
	if err != nil {
		return err
	}
	list := idOn(t, tag+" list")
	if list == "" {
		return fmt.Errorf("the checklist got no id: %q", short(t))
	}
	if _, err := s.ask("notes_read", map[string]any{"id": list}, "- [ ] eggs", "- [x] milk"); err != nil {
		return err
	}
	// delete a note, then the folders (their notes go to Recently Deleted)
	if _, err := s.ask("notes_change", map[string]any{"action": "delete", "id": list}); err != nil {
		return err
	}
	if err := s.holds("notes", "missing", tag+" list"); err != nil {
		return err
	}
	for _, f := range []string{folder, tag + " new folder"} {
		if _, err := s.ask("notes_change", map[string]any{"action": "delete_folder", "folder": f}); err != nil {
			return err
		}
		if left, err := osaOut(`on run argv
tell application "Notes" to return (exists folder (item 1 of argv)) as text
end run`, f); err != nil || left != "false" {
			return fmt.Errorf("the folder %s is still there after delete_folder (%s): %w", f, left, err)
		}
	}
	step("notes: listed, searched, read; created, appended, edited, replaced, renamed, moved, a new folder, a checklist read back, deleted note and folders, as Notes shows")
	return nil
}

func (s *sandbox) calendar() error {
	if err := s.fixture("sweep calendar", "fixture calendar team-sync"); err != nil {
		return err
	}
	defer func() { _ = s.fx.do("sweep calendar") }()
	day := func(n int) string { return time.Now().AddDate(0, 0, n).Format("2006-01-02") }
	if _, err := s.ask("calendar_find", map[string]any{}, evalName); err != nil {
		return fmt.Errorf("the overview: %w", err)
	}
	if _, err := s.ask("calendar_find", map[string]any{"calendar": evalName, "query": "Team sync", "from": day(0), "to": day(3)}, "Team sync"); err != nil {
		return err
	}
	if _, err := s.ask("calendar_find", map[string]any{"calendar": evalName, "free": true, "from": day(1), "to": day(1)}); err != nil {
		return fmt.Errorf("free times: %w", err)
	}
	tag := s.tag()
	if _, err := s.ask("calendar_change", map[string]any{
		"action": "create", "calendar": evalName, "title": tag, "start": day(1) + "T03:00", "end": day(1) + "T03:15",
		"alarms": []any{map[string]any{"minutes_before": 5}},
	}); err != nil {
		// The alarm's shape is the tool's own; an older answer names it: try the plain number.
		if _, err2 := s.ask("calendar_change", map[string]any{
			"action": "create", "calendar": evalName, "title": tag, "start": day(1) + "T03:00", "end": day(1) + "T03:15", "alarms": []any{5},
		}); err2 != nil {
			return errors.Join(err, err2)
		}
	}
	if err := s.holds("calendar", "event-at", tag, "tomorrow", "03:00"); err != nil {
		return err
	}
	t, err := s.ask("calendar_find", map[string]any{"calendar": evalName, "query": tag, "from": day(1), "to": day(1)}, tag)
	if err != nil {
		return err
	}
	id := idOn(t, tag)
	if id == "" {
		return fmt.Errorf("calendar_find gave the event no id: %q", short(t))
	}
	if _, err := s.ask("calendar_find", map[string]any{"id": id}, tag); err != nil {
		return fmt.Errorf("reading the event: %w", err)
	}
	if _, err := s.ask("calendar_change", map[string]any{"action": "update", "id": id, "start": day(1) + "T04:00"}); err != nil {
		return err
	}
	if err := s.holds("calendar", "event-at", tag, "tomorrow", "04:00"); err != nil {
		return fmt.Errorf("after the move: %w", err)
	}
	if mins, err := s.eventMinutes(tag); err != nil || mins != 15 {
		return fmt.Errorf("after the move the event lasts %d minutes, want the 15 it had: %w", mins, err)
	}
	if _, err := s.ask("calendar_change", map[string]any{"action": "update", "id": id, "repeat": "daily", "repeat_count": 3}); err != nil {
		return err
	}
	if _, err := s.ask("calendar_find", map[string]any{"id": id}, "repeat"); err != nil {
		return fmt.Errorf("the repeat isn't said: %w", err)
	}
	if _, err := s.ask("calendar_change", map[string]any{"action": "delete", "id": id, "span": "future"}); err != nil {
		return err
	}
	if err := s.holds("calendar", "count", tag, "0"); err != nil {
		return fmt.Errorf("after delete with span future: %w", err)
	}
	step("calendar: overview, search, free times; created with an alert, read, moved keeping its length, repeated, deleted with its repeats, as Calendar shows")
	return nil
}

// eventMinutes is how long the check's event lasts, as Calendar has it.
func (s *sandbox) eventMinutes(title string) (int, error) {
	out, err := osaOut(`on run argv
tell application "Calendar"
set found to (every event of calendar (item 1 of argv) whose summary is (item 2 of argv))
if (count of found) is 0 then return "-1"
set e to item 1 of found
return (((end date of e) - (start date of e)) div 60) as text
end tell
end run`, evalName, title)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(out)
}

func (s *sandbox) reminders() error {
	if err := s.fixture("sweep reminders", "fixture reminders chores"); err != nil {
		return err
	}
	tag := s.tag()
	defer func() {
		_ = s.fx.do("sweep reminders")
		_ = osa(`on run argv
tell application "Reminders"
if exists list (item 1 of argv) then delete list (item 1 of argv)
end tell
end run`, tag)
	}()
	if _, err := s.ask("reminders_find", map[string]any{"limit": 5}); err != nil {
		return fmt.Errorf("the overview: %w", err)
	}
	t, err := s.ask("reminders_find", map[string]any{"list": evalName}, "Buy stamps", "Pay rent")
	if err != nil {
		return err
	}
	stamps := idOn(t, "Buy stamps")
	if stamps == "" {
		return fmt.Errorf("reminders_find gave Buy stamps no id: %q", short(t))
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "complete", "id": stamps}); err != nil {
		return err
	}
	if err := s.holds("reminders", "completed", "Buy stamps"); err != nil {
		return err
	}
	if err := s.holds("reminders", "not-completed", "Pay rent"); err != nil {
		return err
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "uncomplete", "id": stamps}); err != nil {
		return err
	}
	if err := s.holds("reminders", "not-completed", "Buy stamps"); err != nil {
		return fmt.Errorf("after uncomplete: %w", err)
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "create_list", "title": tag}); err != nil {
		return err
	}
	item := tag + " item"
	due := time.Now().AddDate(0, 0, 3).Format("2006-01-02") + "T09:00"
	if _, err := s.ask("reminders_change", map[string]any{"action": "create", "list": tag, "title": item, "due": due}); err != nil {
		return err
	}
	if due, err := osaOut(`on run argv
tell application "Reminders"
set r to first reminder of list (item 1 of argv) whose name is (item 2 of argv)
set d to due date of r
return ((d - (current date)) div days) as text
end tell
end run`, tag, item); err != nil || (due != "2" && due != "3") {
		return fmt.Errorf("the new reminder isn't due in 3 days as Reminders has it (%q): %w", due, err)
	}
	t, err = s.ask("reminders_find", map[string]any{"list": tag}, item)
	if err != nil {
		return err
	}
	id := idOn(t, item)
	if id == "" {
		return fmt.Errorf("reminders_find gave the new reminder no id: %q", short(t))
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "update", "id": id, "priority": "high", "notes": "changed"}); err != nil {
		return err
	}
	if got, err := osaOut(`on run argv
tell application "Reminders"
set r to first reminder of list (item 1 of argv) whose name is (item 2 of argv)
return ((priority of r) as text) & "|" & (body of r)
end tell
end run`, tag, item); err != nil || !strings.HasPrefix(got, "1|changed") {
		return fmt.Errorf("after update, Reminders has priority|notes %q (%w), want 1 (high)|changed", got, err)
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "complete", "id": id}); err != nil {
		return err
	}
	if _, err := s.ask("reminders_find", map[string]any{"completed": true, "list": tag, "limit": 3}, item); err != nil {
		return fmt.Errorf("the completed list: %w", err)
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "delete", "id": id}); err != nil {
		return err
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "create", "list": tag, "title": tag + " second"}); err != nil {
		return err
	}
	if _, err := s.ask("reminders_change", map[string]any{"action": "delete_list", "list": tag, "reminder_count": 1}); err != nil {
		return err
	}
	if left, err := osaOut(`on run argv
tell application "Reminders" to return (exists list (item 1 of argv)) as text
end run`, tag); err != nil || left != "false" {
		return fmt.Errorf("the list is still there after delete_list (%s, %w)", left, err)
	}
	step("reminders: completed and reopened, a new list, a reminder due in 3 days, updated, completed list, deleted, the list deleted with its count, as Reminders shows")
	return nil
}

func (s *sandbox) contacts() error {
	if err := s.fixture("sweep contacts", "fixture contacts jordan"); err != nil {
		return err
	}
	tag := s.tag()
	family := strings.ReplaceAll(tag, " ", "")
	defer func() {
		_ = s.fx.do("sweep contacts")
		_ = osa(`on run argv
tell application "Contacts"
delete (every person whose last name is (item 1 of argv))
repeat with g in (every group whose name starts with (item 2 of argv))
delete g
end repeat
save
end tell
end run`, family, tag)
	}()
	if _, err := s.ask("contacts_find", map[string]any{}); err != nil {
		return fmt.Errorf("the overview: %w", err)
	}
	t, err := s.ask("contacts_find", map[string]any{"query": "Evaltest"}, "Jordan")
	if err != nil {
		return err
	}
	jordan := idOn(t, "Jordan")
	if jordan == "" {
		return fmt.Errorf("contacts_find gave Jordan Evaltest no id: %q", short(t))
	}
	if _, err := s.ask("contacts_find", map[string]any{"id": jordan}, "Evaltest"); err != nil {
		return fmt.Errorf("reading the card: %w", err)
	}
	email := "jordan." + s.m.marker + "@example.com"
	if _, err := s.ask("contacts_change", map[string]any{"action": "update", "id": jordan, "emails": []any{map[string]any{"label": "work", "value": email}}}); err != nil {
		return err
	}
	if err := s.holds("contacts", "has-email", "Jordan Evaltest", email); err != nil {
		return err
	}
	t, err = s.ask("contacts_change", map[string]any{
		"action": "create", "given_name": "Latchkey", "family_name": family,
		"phones": []any{map[string]any{"label": "mobile", "value": "+15550100"}},
	})
	if err != nil {
		return err
	}
	t2, err := s.ask("contacts_find", map[string]any{"query": family}, family)
	if err != nil {
		return err
	}
	card := idOn(t2, family)
	if card == "" {
		card = idOn(t, family)
	}
	if card == "" {
		return fmt.Errorf("the new card has no id: %q", short(t2))
	}
	if _, err := s.ask("contacts_change", map[string]any{"action": "update", "id": card, "organization": "Check Co"}); err != nil {
		return err
	}
	if org, err := osaOut(`on run argv
tell application "Contacts" to return organization of (first person whose last name is (item 1 of argv))
end run`, family); err != nil || org != "Check Co" {
		return fmt.Errorf("after update, Contacts has the company %q (%w)", org, err)
	}
	group := tag
	steps := []map[string]any{
		{"action": "create_group", "name": group},
		{"action": "add_to_group", "group": group, "id": card},
	}
	for _, a := range steps {
		if _, err := s.ask("contacts_change", a); err != nil {
			return err
		}
	}
	if n, err := osaOut(`on run argv
tell application "Contacts" to return (count of people of group (item 1 of argv)) as text
end run`, group); err != nil || n != "1" {
		return fmt.Errorf("after add_to_group the group holds %q cards (%w)", n, err)
	}
	for _, a := range []map[string]any{
		{"action": "remove_from_group", "group": group, "id": card},
		{"action": "rename_group", "group": group, "name": group + " renamed"},
		{"action": "delete_group", "group": group + " renamed"},
		{"action": "delete", "id": card},
	} {
		if _, err := s.ask("contacts_change", a); err != nil {
			return err
		}
	}
	if left, err := osaOut(`on run argv
tell application "Contacts" to return ((count of (every person whose last name is (item 1 of argv))) + (count of (every group whose name starts with (item 2 of argv)))) as text
end run`, family, tag); err != nil || left != "0" {
		return fmt.Errorf("after the deletes, Contacts still has %q of the check's cards and groups (%w)", left, err)
	}
	step("contacts: overview, search, read; email changed; a card made, changed, put in a group and out, the group renamed and deleted, the card deleted, as Contacts shows")
	return nil
}

// filesFull: the files group (former state-check files.*), every change seen on disk.
func (s *sandbox) filesFull() error {
	if err := s.m.files(); err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, "Downloads", "latchkey-check-"+s.m.marker)
	tilde := "~/Downloads/latchkey-check-" + s.m.marker
	defer func() { _ = os.RemoveAll(dir) }()
	if _, err := s.ask("files_find", map[string]any{"path": "~/Downloads"}); err != nil {
		return err
	}
	if _, err := s.ask("files_change", map[string]any{"action": "create_folder", "path": tilde}); err != nil {
		return err
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return fmt.Errorf("create_folder made no folder: %w", err)
	}
	a := tilde + "/a.txt"
	for _, c := range []map[string]any{
		{"action": "write", "path": a, "text": "one"},
		{"action": "append", "path": a, "text": "\ntwo"},
		{"action": "edit", "path": a, "find": "two", "text": "three"},
	} {
		if _, err := s.ask("files_change", c); err != nil {
			return err
		}
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "one\nthree" { //nolint:gosec // our folder
		return fmt.Errorf("after write, append and edit, a.txt holds %q", b)
	}
	if _, err := s.ask("files_read", map[string]any{"path": a}, "one", "three"); err != nil {
		return err
	}
	if _, err := s.ask("files_find", map[string]any{"path": a}, "a.txt"); err != nil {
		return fmt.Errorf("details: %w", err)
	}
	if _, err := s.ask("files_change", map[string]any{"action": "copy", "path": a, "to": tilde + "/b.txt"}); err != nil {
		return err
	}
	if _, err := s.ask("files_change", map[string]any{"action": "move", "path": tilde + "/b.txt", "to": tilde + "/c.txt"}); err != nil {
		return err
	}
	if b, err := os.ReadFile(filepath.Join(dir, "c.txt")); err != nil || string(b) != "one\nthree" { //nolint:gosec // our folder
		return fmt.Errorf("after copy and move, c.txt holds %q (%w)", b, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "b.txt")); !os.IsNotExist(err) {
		return errors.New("b.txt is still there after the move")
	}
	if err := os.WriteFile(filepath.Join(dir, "report.pdf"), testPDF("Quarterly figures "+s.m.marker), 0o600); err != nil {
		return err
	}
	if _, err := s.ask("files_read", map[string]any{"path": tilde + "/report.pdf"}, "Quarterly figures "+s.m.marker); err != nil {
		return fmt.Errorf("a PDF's text: %w", err)
	}
	// Spotlight finds the folder's file by its content once it has indexed it.
	if !waitFor(60*time.Second, func() bool {
		t, err := s.m.text("files_find", map[string]any{"query": "Quarterly figures " + s.m.marker, "limit": 5})
		return err == nil && strings.Contains(t, "report.pdf")
	}) {
		return errors.New("files_find with a query never found the PDF (Spotlight)")
	}
	if _, err := s.ask("files_change", map[string]any{"action": "trash", "path": tilde}); err != nil {
		return err
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		return errors.New("the folder is still there after trash")
	}
	step("files: listed, made a folder, wrote, appended, edited, read, details, copied, moved, a PDF's text, Spotlight search, trashed, each seen on disk")
	return nil
}

// testPDF is a one-page PDF whose text is text (Helvetica; text without parentheses or
// backslashes).
func testPDF(text string) []byte {
	stream := "BT /F1 18 Tf 72 720 Td (" + text + ") Tj ET"
	objs := []string{
		"<< /Type /Catalog /Pages 2 0 R >>",
		"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
		"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
		fmt.Sprintf("<< /Length %d >>\nstream\n%s\nendstream", len(stream), stream),
		"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
	}
	var b strings.Builder
	b.WriteString("%PDF-1.4\n")
	offsets := make([]int, len(objs))
	for i, o := range objs {
		offsets[i] = b.Len()
		fmt.Fprintf(&b, "%d 0 obj\n%s\nendobj\n", i+1, o)
	}
	xref := b.Len()
	fmt.Fprintf(&b, "xref\n0 %d\n0000000000 65535 f \n", len(objs)+1)
	for _, off := range offsets {
		fmt.Fprintf(&b, "%010d 00000 n \n", off)
	}
	fmt.Fprintf(&b, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(objs)+1, xref)
	return []byte(b.String())
}

// shellFull: the shell group (former state-check shell.*).
func (s *sandbox) shellFull() error {
	if err := s.m.shell(); err != nil {
		return err
	}
	// input to a job that waits for it
	t, err := s.ask("shell_run", map[string]any{"command": "read x; echo got-$x", "wait": 2})
	if err != nil {
		return err
	}
	g := jobRE.FindStringSubmatch(t)
	if g == nil {
		return fmt.Errorf("a command waiting for input didn't become a job: %q", short(t))
	}
	if _, err := s.ask("shell_run", map[string]any{"job": g[1], "input": "abc"}); err != nil {
		return err
	}
	if !waitFor(20*time.Second, func() bool {
		t, err := s.m.text("shell_check", map[string]any{"job": g[1], "wait": 5})
		return err == nil && strings.Contains(t, "got-abc")
	}) {
		return errors.New("the job never showed got-abc after its input")
	}
	// stop
	t, err = s.ask("shell_run", map[string]any{"command": "sleep 300", "wait": 2})
	if err != nil {
		return err
	}
	if g = jobRE.FindStringSubmatch(t); g == nil {
		return fmt.Errorf("sleep 300 didn't become a job: %q", short(t))
	}
	if _, err := s.ask("shell_run", map[string]any{"job": g[1], "stop": true}); err != nil {
		return err
	}
	if _, err := s.ask("shell_check", map[string]any{}, g[1]); err != nil {
		return fmt.Errorf("the job list: %w", err)
	}
	// a declared write outside the allowed places
	home, _ := os.UserHomeDir()
	if _, err := s.ask("shell_run", map[string]any{
		"command": "mkdir -p ~/latchkey-check-dir && echo x > ~/latchkey-check-dir/f && cat ~/latchkey-check-dir/f && rm -r ~/latchkey-check-dir",
		"writes":  []any{"~/latchkey-check-dir"}, "why": "automated check",
	}); err != nil {
		_ = os.RemoveAll(filepath.Join(home, "latchkey-check-dir"))
		return err
	}
	// the local network (the copy's gateway) and the internet
	if _, err := s.ask("shell_run", map[string]any{"command": "r=$(route -n get default | awk '/gateway/{print $2}'); ping -c1 -t3 $r >/dev/null && echo reached-$r"}, "reached-"); err != nil {
		return fmt.Errorf("the local network: %w", err)
	}
	if _, err := s.ask("shell_run", map[string]any{"command": "curl -sS -o /dev/null -w 'http-%{http_code}' https://example.com"}, "http-200"); err != nil {
		return fmt.Errorf("the internet: %w", err)
	}
	// open, declared: an app opened in the background (the screen watch allows it for this call)
	s.m.mayMoveFront = true
	_, err = s.ask("shell_run", map[string]any{"command": "open -g -j -a Calculator && sleep 2 && pkill -x Calculator; echo opened-ok", "uses": []any{"open"}}, "opened-ok")
	s.m.mayMoveFront = false
	if err != nil {
		return err
	}
	step("shell: a job's input, a stopped job, the job list, a declared write, the local network, the internet, open -g")
	return nil
}

// sweep: after the checks, nothing they made is left (former state-check sweep.*): no test data
// in Notes, Calendar, Reminders, Contacts, Downloads, and no page of Claude's still open.
func (s *sandbox) sweep() error {
	tag := s.tag()
	left, err := osaOut(`on run argv
set e to item 1 of argv
set t to item 2 of argv
set found to ""
tell application "Notes"
if exists folder e then set found to found & "a Notes folder " & e & "; "
if (count of (every folder whose name starts with t)) > 0 then set found to found & "a Notes folder " & t & "; "
end tell
tell application "Calendar"
if exists calendar e then set found to found & "a calendar " & e & "; "
end tell
tell application "Reminders"
if exists list e then set found to found & "a Reminders list " & e & "; "
if exists list t then set found to found & "a Reminders list " & t & "; "
end tell
tell application "Contacts"
if (count of (every person whose note is e)) > 0 then set found to found & "a card with the note " & e & "; "
if (count of (every group whose name starts with t)) > 0 then set found to found & "a group " & t & "; "
end tell
return found
end run`, evalName, tag)
	if err != nil {
		return err
	}
	home, _ := os.UserHomeDir()
	entries, _ := os.ReadDir(filepath.Join(home, "Downloads"))
	for _, e := range entries {
		if strings.Contains(e.Name(), s.m.marker) || strings.HasPrefix(e.Name(), "latchkey-check") {
			left += "Downloads/" + e.Name() + "; "
		}
	}
	t, err := s.m.text("browser_look", map[string]any{"tabs": true})
	if err != nil {
		return err
	}
	if g := pageRE.FindAllString(t, -1); len(g) > 0 {
		left += "Claude's pages " + strings.Join(g, ", ") + "; "
	}
	if left != "" {
		return errors.New("left behind: " + strings.TrimSuffix(left, "; "))
	}
	step("sweep: nothing the checks made is left in Notes, Calendar, Reminders, Contacts, Downloads or Claude's pages")
	return nil
}

// maps: places, directions, transit, an address and a place for a position; an answer that says
// Apple Maps is limiting the searches passes (case maps_not_searched_is_not_nothing_found), and
// "found nothing" for these never does.
func (s *sandbox) maps() error {
	for _, c := range []struct {
		what string
		args map[string]any
		want []string
	}{
		{"places", map[string]any{"query": "coffee", "near": "37.7793,-122.4193", "limit": 3}, nil},
		{"directions", map[string]any{"from": "Walnut Creek, CA", "to": "San Francisco International Airport"}, []string{"min"}},
		{"transit", map[string]any{"from": "Union Square, San Francisco", "to": "San Francisco City Hall", "mode": "transit"}, nil},
		{"an address", map[string]any{"address": "1 Infinite Loop, Cupertino"}, []string{"Cupertino"}},
		{"a position", map[string]any{"address": "37.3318,-122.0312"}, []string{"Cupertino"}},
	} {
		res, err := s.m.call("maps_find", c.args)
		if err != nil {
			return fmt.Errorf("%s: %w", c.what, err)
		}
		t := e2erelay.TextOf(res)
		low := strings.ToLower(t)
		if strings.Contains(low, "limit") && strings.Contains(low, "again") {
			step("maps %s: Apple Maps is limiting the searches, and says so", c.what)
			continue
		}
		if res.IsError || strings.Contains(low, "found nothing") || strings.Contains(low, "no places") {
			return fmt.Errorf("maps_find %s %v: %q", c.what, c.args, short(t))
		}
		for _, w := range c.want {
			if !strings.Contains(low, strings.ToLower(w)) {
				return fmt.Errorf("maps_find %s: the answer lacks %q: %q", c.what, w, short(t))
			}
		}
	}
	step("maps: places, directions, transit, an address and a position's place")
	return nil
}
