// Command latchkey is Latchkey's server program for Linux (spec 010; contracts/server-program.md).
//
//	latchkey install --relay https://relay.example [--name homeserver]
//	latchkey status | shell on|off | files off|read|write | pause | resume | rename NAME
//	latchkey activity [--check] | update | uninstall | version
//	latchkey run        (what the systemd service runs)
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/tonimelisma/latchkey/linux/internal/activity"
	"github.com/tonimelisma/latchkey/linux/internal/agent"
	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/devicekey"
	"github.com/tonimelisma/latchkey/linux/internal/files"
	"github.com/tonimelisma/latchkey/linux/internal/setup"
	"github.com/tonimelisma/latchkey/linux/internal/shell"
	"github.com/tonimelisma/latchkey/linux/internal/update"
)

// version is set when a release is built (-ldflags "-X main.version=…").
var version = "dev"

const usage = `Latchkey for Linux servers: Claude's access to this server, through your Latchkey relay.

  latchkey install --relay URL [--name NAME]   pair this server with your account and start the service
  latchkey status                              what is on, the relay, the name, the version
  latchkey shell on|off                        Shell: Claude runs commands as you (sudo where you allowed it without a password)
  latchkey files off|read|write                Files: Claude finds and reads, or also changes, your files
  latchkey pause | resume                      answer every call "paused", or stop doing so
  latchkey rename NAME                         the name Claude sees for this server
  latchkey activity [--check]                  the last 50 things Claude did here, or the last audit check
  latchkey update                              install the newest release now
  latchkey uninstall                           remove this server from your account and delete Latchkey
  latchkey version
`

func main() {
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(2)
	}
	paths, err := config.DefaultPaths()
	if err != nil {
		fail(err)
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "install":
		err = install(paths, args)
	case "run":
		err = run(paths)
	case "status":
		err = status(paths)
	case "shell":
		err = setLevel(paths, args, func(s *config.Settings, v string) error {
			if v != config.On && v != config.Off {
				return errors.New("say latchkey shell on, or latchkey shell off")
			}
			s.Shell = v
			return nil
		})
	case "files":
		err = setLevel(paths, args, func(s *config.Settings, v string) error {
			if v != config.FilesOff && v != config.FilesRead && v != config.FilesWrite {
				return errors.New("say latchkey files off, read, or write")
			}
			s.Files = v
			return nil
		})
	case "pause", "resume":
		err = change(paths, func(s *config.Settings) { s.Paused = cmd == "pause" })
		if err == nil && cmd == "pause" {
			fmt.Println("Paused: Claude's calls are answered \"paused\" and running commands were stopped. latchkey resume turns access back on.")
		} else if err == nil {
			fmt.Println("Resumed: Claude can use this server again.")
		}
	case "rename":
		name := strings.TrimSpace(strings.Join(args, " "))
		if name == "" {
			err = errors.New("say the new name: latchkey rename homeserver")
			break
		}
		err = change(paths, func(s *config.Settings) { s.Name = name })
		if err == nil {
			fmt.Printf("Renamed to %q. The relay keeps names unique: latchkey status shows the name in a moment.\n", name)
		}
	case "activity":
		err = showActivity(paths, args)
	case "update":
		err = updateNow(paths)
	case "uninstall":
		err = uninstall(paths)
	case "version", "--version", "-v":
		fmt.Println("latchkey " + version)
	case "help", "--help", "-h":
		fmt.Print(usage)
	default:
		fmt.Print(usage)
		os.Exit(2)
	}
	if err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "latchkey: "+err.Error())
	os.Exit(1)
}

func change(p config.Paths, f func(*config.Settings)) error {
	s, err := config.Load(p)
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("this server isn't set up yet: run latchkey install --relay https://your-relay")
	}
	if err != nil {
		return err
	}
	f(&s)
	return config.Save(p, s)
}

func setLevel(p config.Paths, args []string, f func(*config.Settings, string) error) error {
	if len(args) != 1 {
		return errors.New("give one value, for example latchkey shell off")
	}
	var inner error
	err := change(p, func(s *config.Settings) { inner = f(s, strings.ToLower(args[0])) })
	if inner != nil {
		return inner
	}
	if err == nil {
		fmt.Println("Done; the service follows within a second.")
	}
	return err
}

func install(p config.Paths, args []string) error {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	relay := fs.String("relay", "", "your relay's address, https://…")
	name := fs.String("name", "", "the name Claude sees (default: the hostname)")
	noService := fs.Bool("no-service", false, "pair only; don't install the systemd service (for tests and development)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !*noService {
		if err := setup.Check(); err != nil {
			return err
		}
	}
	s, err := config.Load(p)
	switch {
	case errors.Is(err, os.ErrNotExist):
		s = config.Defaults()
	case err != nil:
		return err
	}
	if *relay != "" {
		r := strings.TrimRight(strings.TrimSpace(*relay), "/")
		// Plain http only for a relay on this machine, or a test relay when asked for explicitly.
		if !strings.HasPrefix(r, "https://") && !strings.HasPrefix(r, "http://localhost") &&
			(!strings.HasPrefix(r, "http://") || os.Getenv("LATCHKEY_TEST_INSECURE_RELAY") != "1") {
			return errors.New("the relay's address starts with https://")
		}
		if r != s.Relay {
			s.DeviceID = "" // another relay: pair again
		}
		s.Relay = r
	}
	if s.Relay == "" {
		return errors.New("give your relay's address: latchkey install --relay https://your-relay")
	}
	if *name != "" {
		s.Name = *name
	}
	program, err := setup.InstallProgram(p)
	if err != nil {
		return fmt.Errorf("couldn't put the program in %s: %w", p.Program, err)
	}
	if _, keyErr := devicekey.Load(p.Key); s.DeviceID == "" || keyErr != nil {
		key, err := devicekey.New()
		if err != nil {
			return err
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		pairing, err := setup.Start(ctx, s.Relay, s.MachineName(), key.PublicKey())
		if err != nil {
			return err
		}
		fmt.Printf("\nTo connect this server to your Latchkey account, open\n\n    %s\n\non any device where you're signed in to the relay, and enter the code\n\n    %s\n\n(The code works for %d minutes. Waiting…)\n",
			pairing.VerificationURI, pairing.UserCode, pairing.ExpiresIn/60)
		paired, err := setup.Wait(ctx, s.Relay, pairing)
		if err != nil {
			return err
		}
		if err := key.Save(p.Key); err != nil {
			return err
		}
		s.DeviceID = paired.DeviceID
		if err := config.Save(p, s); err != nil {
			return err
		}
		fmt.Printf("Paired as %q.\n", paired.Name)
	} else if err := config.Save(p, s); err != nil {
		return err
	}
	if *noService {
		fmt.Println("Paired. Start it with: latchkey run")
		return nil
	}
	fmt.Println("\nStarting the service (sudo may ask for your password once)…")
	if err := setup.InstallService(p, setup.Terminal); err != nil {
		return err
	}
	fmt.Printf("\nDone. Claude can reach this server through your Latchkey connector.\nShell is %s and Files is %s; change them with latchkey shell and latchkey files.\n"+
		"Program: %s (the latchkey command is in %s; log in again if your shell doesn't find it yet)\n",
		s.Shell, filesWord(s.Files), program, p.Command)
	return nil
}

func filesWord(level string) string {
	switch level {
	case config.FilesRead:
		return "read only"
	case config.FilesWrite:
		return "read & write"
	}
	return "off"
}

func status(p config.Paths) error {
	s, err := config.Load(p)
	if errors.Is(err, os.ErrNotExist) {
		fmt.Println("Latchkey isn't set up here. Run latchkey install --relay https://your-relay")
		return nil
	}
	if err != nil {
		return err
	}
	paired := "not paired (run latchkey install)"
	if s.DeviceID != "" {
		paired = "paired"
	}
	fmt.Printf("Latchkey %s\nRelay: %s (%s)\nName: %s\nShell: %s\nFiles: %s\n", version, s.Relay, paired, s.MachineName(), s.Shell, filesWord(s.Files))
	if s.Paused {
		fmt.Println("Paused: every call is answered \"paused\" (latchkey resume)")
	}
	if out, err := exec.CommandContext(context.Background(), "systemctl", "is-active", "latchkey").Output(); err == nil || len(out) > 0 {
		fmt.Println("Service: " + strings.TrimSpace(string(out)))
	}
	if entries, err := activity.Read(p.Activity, time.Time{}); err == nil {
		for i := len(entries) - 1; i >= 0; i-- {
			if e := entries[i]; e.Kind == "event" && strings.HasPrefix(e.Text, "Connected to ") {
				fmt.Printf("Last connected: %s, %s\n", e.At.Local().Format("2006-01-02 15:04"), strings.TrimPrefix(e.Text, "Connected to "))
				break
			}
		}
	}
	return nil
}

func showActivity(p config.Paths, args []string) error {
	entries, err := activity.Read(p.Activity, time.Time{})
	if errors.Is(err, os.ErrNotExist) {
		fmt.Println("Nothing yet.")
		return nil
	}
	if err != nil {
		return err
	}
	if len(args) > 0 && args[0] == "--check" {
		for i := len(entries) - 1; i >= 0; i-- {
			if strings.HasPrefix(entries[i].Text, "Audit check") {
				fmt.Printf("%s  %s\n(The service compares its log with the relay's audit every time it connects.)\n",
					entries[i].At.Local().Format("2006-01-02 15:04:05"), entries[i].Text)
				return nil
			}
		}
		fmt.Println("No audit check yet; the service runs one each time it connects.")
		return nil
	}
	activity.Print(os.Stdout, entries, 50)
	return nil
}

func updateNow(p config.Paths) error {
	s, err := config.Load(p)
	if err != nil {
		return err
	}
	v, err := update.New(p, s, version).Update(context.Background())
	if errors.Is(err, update.ErrUpToDate) {
		fmt.Println("Latchkey " + version + " is the newest.")
		return nil
	}
	if err != nil {
		return err
	}
	fmt.Println("Installed " + v + "; restarting the service (sudo may ask for your password)…")
	return setup.Terminal("sudo", "systemctl", "restart", "latchkey")
}

func uninstall(p config.Paths) error {
	s, err := config.Load(p)
	if err == nil && s.DeviceID != "" {
		if key, err := devicekey.Load(p.Key); err == nil {
			if err := agent.Unpair(context.Background(), s, key, version); err != nil {
				fmt.Printf("Couldn't tell the relay (%v); remove this server on the relay's account page too.\n", err)
			} else {
				fmt.Println("Removed from your account.")
			}
		}
	}
	fmt.Println("Stopping and removing the service (sudo may ask for your password)…")
	serviceErr := setup.RemoveService(p, setup.Terminal)
	if err := setup.RemoveFiles(p); err != nil {
		return err
	}
	if serviceErr != nil {
		return fmt.Errorf("the files are gone, but removing the service failed: %w", serviceErr)
	}
	fmt.Println("Latchkey is uninstalled; nothing of it is left on this server.")
	return nil
}

// run is the service: connected until systemd stops it, updating itself daily.
func run(p config.Paths) error {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	log, err := activity.Open(p.Activity)
	if err != nil {
		return err
	}
	s, _ := config.Load(p)
	up := update.New(p, s, version)
	if rollBack, awaiting := up.Started(); rollBack {
		log.Event("Version %s went back to the previous version: it never connected", version)
		os.Exit(1) // systemd starts the previous version
	} else if awaiting {
		go func() {
			time.Sleep(3 * time.Minute)
			if !up.Confirmed() {
				if up.RollBack("not welcomed within 3 minutes") == nil {
					log.Event("Version %s went back to the previous version: the relay didn't welcome it within 3 minutes", version)
					os.Exit(1)
				}
			}
		}()
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	a := &agent.Agent{
		Paths: p, Version: version, Logger: logger, Log: log,
		Shell: shell.New(p), Files: files.New(p),
		OnWelcome: up.Confirm,
		Stopping: func() bool {
			out, _ := exec.CommandContext(context.Background(), "systemctl", "is-system-running").Output()
			return strings.TrimSpace(string(out)) == "stopping"
		},
	}
	go dailyUpdates(ctx, p, log, logger, stop)
	return a.Run(ctx)
}

// dailyUpdates checks for a new release 10 minutes after start and then daily; an installed
// update ends the service, which systemd starts again as the new version.
func dailyUpdates(ctx context.Context, p config.Paths, log *activity.Log, logger *slog.Logger, stop func()) {
	wait := 10 * time.Minute
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		wait = 24 * time.Hour
		s, err := config.Load(p)
		if err != nil || !s.AutoUpdates() {
			continue
		}
		v, err := update.New(p, s, version).Update(ctx)
		switch {
		case errors.Is(err, update.ErrUpToDate):
		case err != nil:
			logger.Warn("update check failed", "err", err)
		default:
			log.Event("Updated from %s to %s; restarting", version, v)
			stop()
			return
		}
	}
}
