// Command e2e is spec 015's end-to-end tests and evals:
//
//	e2e pick -base <ref>        which checks the changed files select (FR-1500), for e2e.yml
//	e2e relay [-update-snapshots]  the relay's own tools through a private relay (FR-1501, FR-1504)
//	e2e mac -checks a,b [-update-snapshots]  the Mac app's real tools on this Mac (GitHub's runner)
//	e2e weekly                  inside the test Mac copy: checks and Claude tasks (FR-1515, FR-1516)
//	e2e prepare                 inside the test Mac image, once: the relay's account and pairing
//	e2e fixture <command>       set up, check and clean test data on the test Mac (FR-1520)
//	e2e send <result.json>      seal a weekly result to the developer's key and send it (FR-1530)
//
// Run from relay/. Nothing here reaches anyone's real data: every relay is private to the run.
package main

import (
	"fmt"
	"os"
)

const usage = `usage: e2e pick|relay|mac|weekly|prepare|fixture|send ... (see the package comment)`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	args := os.Args[2:]
	switch os.Args[1] {
	case "pick":
		err = pickCmd(args)
	case "relay":
		err = relayCmd(args)
	case "mac":
		err = macCmd(args)
	case "weekly":
		err = weeklyCmd(args)
	case "prepare":
		err = prepareCmd(args)
	case "fixture":
		err = fixtureCmd(args)
	case "send":
		err = sendCmd(args)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
}

func step(format string, args ...any) { fmt.Printf("• "+format+"\n", args...) }
