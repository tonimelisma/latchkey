package main

import (
	"strings"
	"testing"
)

var testDisplay = []screenWindow{{X: 0, Y: 0, W: 1024, H: 768}}

func screen(front string, pid int, wins ...screenWindow) screenState {
	return screenState{Front: front, FrontID: pid, MouseX: 100, MouseY: 200, Clip: 7, Windows: wins}
}

func TestScreenChangesSeesWhatAPersonWould(t *testing.T) {
	finder := screenWindow{Owner: "Finder", PID: 10, ID: 1, W: 800, H: 600}
	before := screen("Finder", 10, finder)

	if c, p := screenChanges(before, before, testDisplay, false); len(c)+len(p) != 0 {
		t.Fatalf("nothing changed: %v %v", c, p)
	}
	notes := screenWindow{Owner: "Notes", PID: 20, ID: 2, X: 100, Y: 100, W: 600, H: 400}
	now := screen("Notes", 20, finder, notes)
	now.MouseX, now.Clip = 300, 8
	c, p := screenChanges(before, now, testDisplay, false)
	for _, want := range []string{"window of Notes appeared", "app in front changed from Finder to Notes", "pointer moved", "clipboard changed"} {
		if !strings.Contains(strings.Join(c, "; "), want) {
			t.Errorf("want %q in %v", want, c)
		}
	}
	if len(p) != 0 {
		t.Errorf("no question asked: %v", p)
	}
}

// Latchkey's own browser draws outside every display, and menu-bar items are another layer:
// neither is something that appeared in front of the person.
func TestScreenChangesIgnoresOffScreenAndOtherLayers(t *testing.T) {
	before := screen("Finder", 10)
	hidden := screenWindow{Owner: "Latchkey", PID: 30, ID: 3, X: -20000, Y: -20000, W: 1280, H: 900}
	menu := screenWindow{Owner: "Latchkey", PID: 30, ID: 4, Layer: 25, X: 900, Y: 0, W: 30, H: 24}
	tiny := screenWindow{Owner: "Safari", PID: 40, ID: 5, X: 10, Y: 10, W: 1, H: 1}
	if c, p := screenChanges(before, screen("Finder", 10, hidden, menu, tiny), testDisplay, false); len(c)+len(p) != 0 {
		t.Fatalf("off screen, menu bar, a 1-point window: %v %v", c, p)
	}
}

// A permission question counts even during computer control, which may change what is in front.
func TestScreenChangesPromptsAlwaysCount(t *testing.T) {
	before := screen("Finder", 10)
	ask := screenWindow{Owner: "UserNotificationCenter", PID: 50, ID: 6, Layer: 0, X: 300, Y: 200, W: 260, H: 300}
	other := screenWindow{Owner: "TextEdit", PID: 60, ID: 7, X: 0, Y: 0, W: 500, H: 500}
	now := screen("TextEdit", 60, ask, other)
	now.MouseX = 400
	c, p := screenChanges(before, now, testDisplay, true)
	if len(c) != 0 {
		t.Errorf("computer control may change the front, the pointer and windows: %v", c)
	}
	if len(p) != 1 || !strings.Contains(p[0], "UserNotificationCenter") {
		t.Errorf("the question: %v", p)
	}
}

func TestWatchVerdict(t *testing.T) {
	if v := watchVerdict("x", nil, 0); !strings.Contains(v, "no samples") {
		t.Errorf("no samples must fail: %q", v)
	}
	if v := watchVerdict("x", nil, 40); v != "" {
		t.Errorf("nothing found passes: %q", v)
	}
	many := make([]string, 11)
	for i := range many {
		many[i] = "c"
	}
	if v := watchVerdict("seen", many, 40); !strings.Contains(v, "and 3 more") {
		t.Errorf("long lists are cut: %q", v)
	}
}
