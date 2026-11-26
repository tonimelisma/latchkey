package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"
)

// The checks "front-app-unchanged" and "no-permission-prompts" (relay/e2e/sandbox-checks.md;
// the retired focus-watch.swift and regressions.never_disturb_*): while Latchkey answers a tool
// call, nothing a person at the Mac sees may change (Constitution IV): the app in front, the
// pointer, the clipboard, and no other app's window appears; and no macOS permission question
// appears at all. A sampler inside the sandbox copy reports the screen's state about three times
// a second; each tool call is compared with the state just before it.

// screenState is one sample.
type screenState struct {
	Front   string         `json:"front"`
	FrontID int            `json:"pid"`
	MouseX  float64        `json:"mx"`
	MouseY  float64        `json:"my"`
	Clip    int            `json:"clip"`
	Windows []screenWindow `json:"windows"`
}

type screenWindow struct {
	Owner string  `json:"owner"`
	PID   int     `json:"pid"`
	ID    int     `json:"id"`
	Layer int     `json:"layer"`
	X     float64 `json:"x"`
	Y     float64 `json:"y"`
	W     float64 `json:"w"`
	H     float64 `json:"h"`
}

// promptOwners are the processes that draw macOS's permission questions and password sheets.
var promptOwners = []string{
	"UserNotificationCenter", "universalAccessAuthWarn", "SecurityAgent", "CoreServicesUIAgent",
	"coreautha", "CoreLocationAgent", "tccd", "System Settings", "System Preferences",
}

// seenOnScreen says whether a window shows on the copy's screen (Latchkey's own browser keeps its
// window outside every display, where no one sees it: spec 005).
func (w screenWindow) seenOnScreen(displays []screenWindow) bool {
	if w.W <= 1 || w.H <= 1 {
		return false
	}
	for _, d := range displays {
		if w.X < d.X+d.W && w.X+w.W > d.X && w.Y < d.Y+d.H && w.Y+w.H > d.Y {
			return true
		}
	}
	return false
}

// screenChanges lists what changed between before and during a tool call that a person would
// notice; prompts lists the permission questions that showed. allowFront: the call may change the
// app in front, the pointer and the windows (computer control, the shell's open).
func screenChanges(before, now screenState, displays []screenWindow, allowFront bool) (changes, prompts []string) {
	had := map[int]bool{}
	for _, w := range before.Windows {
		had[w.ID] = true
	}
	for _, w := range now.Windows {
		if slices.Contains(promptOwners, w.Owner) && w.seenOnScreen(displays) {
			prompts = append(prompts, fmt.Sprintf("a window of %s (a macOS question) appeared", w.Owner))
			continue
		}
		if allowFront || had[w.ID] || w.Layer != 0 || !w.seenOnScreen(displays) {
			continue
		}
		changes = append(changes, fmt.Sprintf("a window of %s appeared on the screen", w.Owner))
	}
	if allowFront {
		return changes, prompts
	}
	if now.FrontID != before.FrontID {
		changes = append(changes, fmt.Sprintf("the app in front changed from %s to %s", before.Front, now.Front))
	}
	if math.Abs(now.MouseX-before.MouseX) > 0.5 || math.Abs(now.MouseY-before.MouseY) > 0.5 {
		changes = append(changes, fmt.Sprintf("the pointer moved from %.0f,%.0f to %.0f,%.0f", before.MouseX, before.MouseY, now.MouseX, now.MouseY))
	}
	if now.Clip != before.Clip {
		changes = append(changes, "the clipboard changed")
	}
	return changes, prompts
}

// samplerJS prints a screenState as a line of JSON every 300 ms (JavaScript for Automation; the
// window list's owners need no permission). The first line is the displays.
const samplerJS = `ObjC.import('AppKit'); ObjC.import('CoreGraphics');
function out(o) { $.NSFileHandle.fileHandleWithStandardOutput.writeData($(JSON.stringify(o) + "\n").dataUsingEncoding($.NSUTF8StringEncoding)); }
function run() {
  var ds = [];
  var n = $.NSScreen.screens.count;
  for (var i = 0; i < n; i++) { var f = $.NSScreen.screens.objectAtIndex(i).frame; ds.push({x: f.origin.x, y: 0, w: f.size.width, h: f.size.height}); }
  out({displays: ds});
  while (true) {
    var ws = $.NSWorkspace.sharedWorkspace; var fr = ws.frontmostApplication;
    var m = $.NSEvent.mouseLocation;
    var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, $.kCGNullWindowID))) || [];
    var wins = list.map(function (w) { var b = w.kCGWindowBounds || {}; return {owner: w.kCGWindowOwnerName || "", pid: w.kCGWindowOwnerPID || 0, id: w.kCGWindowNumber || 0, layer: w.kCGWindowLayer || 0, x: b.X || 0, y: b.Y || 0, w: b.Width || 0, h: b.Height || 0}; });
    out({front: fr ? fr.localizedName.js : "", pid: fr ? fr.processIdentifier : 0, mx: m.x, my: m.y, clip: $.NSPasteboard.generalPasteboard.changeCount, windows: wins});
    delay(0.3);
  }
}`

// screenWatch runs the sampler and keeps what it found during tool calls.
type screenWatch struct {
	cmd      *exec.Cmd
	displays []screenWindow

	mu       sync.Mutex
	last     screenState
	have     bool
	inCall   bool
	allow    bool
	before   screenState
	label    string
	found    map[string]bool // "label: change", kept once each
	changes  []string
	prompts  []string
	sampled  int
	stopOnce sync.Once
}

// startScreenWatch starts the sampler; it fails if no sample came within 10 s.
func startScreenWatch(ctx context.Context) (*screenWatch, error) {
	cmd := exec.CommandContext(ctx, "/usr/bin/osascript", "-l", "JavaScript", "-e", samplerJS) //nolint:gosec // fixed script
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	w := &screenWatch{cmd: cmd, found: map[string]bool{}}
	ready := make(chan struct{})
	go func() {
		sc := bufio.NewScanner(out)
		sc.Buffer(make([]byte, 1<<20), 1<<22)
		first := true
		for sc.Scan() {
			if first {
				var d struct {
					Displays []screenWindow `json:"displays"`
				}
				if json.Unmarshal(sc.Bytes(), &d) == nil {
					w.displays = d.Displays
				}
				first = false
				continue
			}
			var s screenState
			if json.Unmarshal(sc.Bytes(), &s) != nil {
				continue
			}
			w.sample(s)
			if w.sampled == 1 {
				close(ready)
			}
		}
	}()
	select {
	case <-ready:
		return w, nil
	case <-time.After(10 * time.Second):
		w.stop()
		return nil, fmt.Errorf("the screen sampler (osascript) gave no sample in 10 s")
	}
}

func (w *screenWatch) sample(s screenState) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.last, w.have = s, true
	w.sampled++
	if !w.inCall {
		return
	}
	changes, prompts := screenChanges(w.before, s, w.displays, w.allow)
	for _, c := range changes {
		if k := w.label + ": " + c; !w.found[k] {
			w.found[k] = true
			w.changes = append(w.changes, k)
		}
	}
	for _, p := range prompts {
		if k := w.label + ": " + p; !w.found[k] {
			w.found[k] = true
			w.prompts = append(w.prompts, k)
		}
	}
}

// during runs a tool call with the screen compared against the moment before it.
func (w *screenWatch) during(label string, allowFront bool, call func()) {
	w.waitSample()
	w.mu.Lock()
	w.before, w.inCall, w.allow, w.label = w.last, true, allowFront, label
	w.mu.Unlock()
	call()
	w.waitSample() // a sample after the answer, for what showed at the end
	w.mu.Lock()
	w.inCall = false
	w.mu.Unlock()
}

// waitSample waits for the next sample (up to 2 s).
func (w *screenWatch) waitSample() {
	w.mu.Lock()
	n := w.sampled
	w.mu.Unlock()
	waitFor(2*time.Second, func() bool {
		w.mu.Lock()
		defer w.mu.Unlock()
		return w.sampled > n
	})
}

// findings is what was seen so far: changes a person would notice, and permission questions.
func (w *screenWatch) findings() (changes, prompts []string, samples int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.changes), slices.Clone(w.prompts), w.sampled
}

func (w *screenWatch) stop() {
	w.stopOnce.Do(func() {
		if w.cmd.Process != nil {
			_ = w.cmd.Process.Kill()
		}
		_ = w.cmd.Wait()
	})
}

// watchVerdict turns findings into a check's error ("" passes).
func watchVerdict(what string, found []string, samples int) string {
	if samples == 0 {
		return "the screen sampler gave no samples"
	}
	if len(found) == 0 {
		return ""
	}
	if len(found) > 8 {
		found = append(found[:8:8], fmt.Sprintf("and %d more", len(found)-8))
	}
	return what + ": " + strings.Join(found, "; ")
}
