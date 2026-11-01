// Package update keeps the server program up to date (spec 010 FR-1026, plan D12): it looks for
// the newest server-v* release of the repository daily, checks the download's Ed25519 signature
// against the key built into the program, replaces itself, and exits so systemd starts the new
// version. A new version that isn't welcomed by the relay within 3 minutes, or crashes 3 times,
// puts the previous one back; a version rolled back is skipped until a newer one appears.
package update

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/linux/internal/config"
)

// Release is one server release.
type Release struct {
	Version   string // "0.1.2", without the tag's prefix
	Binary    string // download address of the program for this architecture
	Signature string // download address of its .sig
}

// TagPrefix starts every server release's tag.
const TagPrefix = "server-v"

// Updater does the work; its fields are set for tests.
type Updater struct {
	Paths   config.Paths
	Repo    string // owner/name
	Current string // this program's version
	PubKey  ed25519.PublicKey
	API     string // https://api.github.com
	HTTP    *http.Client
	Now     func() time.Time
}

// New makes an updater for the settings' repository and the built-in key.
func New(p config.Paths, s config.Settings, current string) *Updater {
	return &Updater{
		Paths: p, Repo: s.Repo(), Current: current, PubKey: PublicKey(), API: "https://api.github.com",
		HTTP: &http.Client{Timeout: 2 * time.Minute}, Now: time.Now,
	}
}

// State is update.json: what the last update did, for the new version to confirm or undo.
type State struct {
	Version   string    `json:"version,omitempty"`   // the version installed by the last update
	Previous  string    `json:"previous,omitempty"`  // the version it replaced
	Confirmed bool      `json:"confirmed,omitempty"` // welcomed by the relay
	Starts    int       `json:"starts,omitempty"`    // starts since it was installed, unconfirmed
	At        time.Time `json:"at"`
	Skip      []string  `json:"skip,omitempty"` // versions rolled back
}

func (u *Updater) load() State {
	var s State
	if data, err := os.ReadFile(u.Paths.Update); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	return s
}

func (u *Updater) save(s State) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(u.Paths.Update), 0o700); err != nil {
		return err
	}
	return config.WriteAtomic(u.Paths.Update, data, 0o600)
}

// Newer reports whether version a is newer than b (dotted numbers).
func Newer(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := range max(len(pa), len(pb)) {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

// Latest finds the newest server release with a program for this architecture.
func (u *Updater) Latest(ctx context.Context) (Release, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/repos/%s/releases?per_page=50", u.API, u.Repo), nil)
	if err != nil {
		return Release{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := u.HTTP.Do(req)
	if err != nil {
		return Release{}, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return Release{}, fmt.Errorf("GitHub answered %s", resp.Status)
	}
	var list []struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&list); err != nil {
		return Release{}, err
	}
	want := "latchkey-linux-" + runtime.GOARCH
	var best Release
	for _, r := range list {
		v, ok := strings.CutPrefix(r.Tag, TagPrefix)
		if !ok || r.Draft || r.Prerelease || (best.Version != "" && !Newer(v, best.Version)) {
			continue
		}
		var rel Release
		for _, a := range r.Assets {
			switch a.Name {
			case want:
				rel.Binary = a.URL
			case want + ".sig":
				rel.Signature = a.URL
			}
		}
		if rel.Binary != "" && rel.Signature != "" {
			rel.Version = v
			best = rel
		}
	}
	if best.Version == "" {
		return Release{}, errors.New("no server release for " + runtime.GOARCH)
	}
	return best, nil
}

func (u *Updater) download(ctx context.Context, url string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := u.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", url, resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s is larger than expected", url)
	}
	return data, nil
}

// Signed is what a release signature covers: the program's architecture, its version, and its
// SHA-256, so a signed older program can't be passed off under a newer release's tag (security
// review, 2026-10-31).
func Signed(arch, version string, data []byte) []byte {
	return fmt.Appendf(nil, "latchkey-linux-%s %s %x\n", arch, version, sha256.Sum256(data))
}

// Verify checks a release program against its signature (base64 Ed25519 over Signed).
func Verify(pub ed25519.PublicKey, arch, version string, data, sig []byte) error {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig)))
	if err != nil || len(raw) != ed25519.SignatureSize {
		return errors.New("the signature is malformed")
	}
	if !ed25519.Verify(pub, Signed(arch, version, data), raw) {
		return fmt.Errorf("the signature doesn't match: the download isn't Latchkey's signed release %s for %s", version, arch)
	}
	return nil
}

// ErrUpToDate: nothing newer (or only versions rolled back before).
var ErrUpToDate = errors.New("up to date")

// Update installs the newest release if it is newer, and returns its version. The caller exits so
// systemd starts it.
func (u *Updater) Update(ctx context.Context) (string, error) {
	rel, err := u.Latest(ctx)
	if err != nil {
		return "", err
	}
	st := u.load()
	if !Newer(rel.Version, u.Current) || contains(st.Skip, rel.Version) {
		return "", ErrUpToDate
	}
	bin, err := u.download(ctx, rel.Binary, 200<<20)
	if err != nil {
		return "", err
	}
	sig, err := u.download(ctx, rel.Signature, 4096)
	if err != nil {
		return "", err
	}
	if err := Verify(u.PubKey, runtime.GOARCH, rel.Version, bin, sig); err != nil {
		return "", err
	}
	program := filepath.Join(u.Paths.Program, "latchkey")
	if err := os.MkdirAll(u.Paths.Program, 0o755); err != nil { //nolint:gosec // the program's folder; the program must be runnable
		return "", err
	}
	if err := copyFile(program, program+".previous"); err != nil {
		return "", fmt.Errorf("couldn't keep the current version: %w", err)
	}
	if err := config.WriteAtomic(program, bin, 0o755); err != nil {
		return "", err
	}
	st.Version, st.Previous, st.Confirmed, st.Starts, st.At = rel.Version, u.Current, false, 0, u.Now().UTC()
	return rel.Version, u.save(st)
}

func copyFile(from, to string) error {
	data, err := os.ReadFile(from) //nolint:gosec // the program's own file, being kept as the previous version
	if err != nil {
		return err
	}
	return config.WriteAtomic(to, data, 0o755)
}

func contains(list []string, v string) bool {
	for _, s := range list {
		if s == v {
			return true
		}
	}
	return false
}

// Started is called when the program starts. For an unconfirmed update it counts the start; at
// the third unconfirmed start it rolls back at once (true: the caller exits so the previous
// version starts). It returns whether a confirmation is awaited.
func (u *Updater) Started() (rollBack, awaiting bool) {
	st := u.load()
	if st.Version == "" || st.Confirmed || st.Version != u.Current {
		return false, false
	}
	st.Starts++
	_ = u.save(st)
	if st.Starts >= 3 {
		return u.RollBack("it stopped 3 times without connecting") == nil, false
	}
	return false, true
}

// Confirm marks the running version good: the relay welcomed it.
func (u *Updater) Confirm() {
	st := u.load()
	if st.Version == u.Current && !st.Confirmed {
		st.Confirmed = true
		_ = u.save(st)
	}
}

// Confirmed reports whether the running version has been welcomed (or wasn't an update).
func (u *Updater) Confirmed() bool {
	st := u.load()
	return st.Version != u.Current || st.Confirmed
}

// RollBack puts the previous version back and skips this one from now on.
func (u *Updater) RollBack(why string) error {
	program := filepath.Join(u.Paths.Program, "latchkey")
	if _, err := os.Stat(program + ".previous"); err != nil {
		return fmt.Errorf("no previous version to go back to: %w", err)
	}
	if err := os.Rename(program+".previous", program); err != nil {
		return err
	}
	st := u.load()
	st.Skip = append(st.Skip, st.Version)
	st.Confirmed = true // the previous version, known good
	st.Version, st.Starts = st.Previous, 0
	_ = why
	return u.save(st)
}
