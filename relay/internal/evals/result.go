package evals

import (
	"crypto/hmac"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/reports"
)

// Result is a weekly run's result (contracts/eval-result.md, FR-1522, FR-1530).
type Result struct {
	Kind       string    `json:"kind"` // always "eval"
	Format     int       `json:"format"`
	Run        string    `json:"run"`
	Part       int       `json:"part"`
	Parts      int       `json:"parts"`
	Started    time.Time `json:"started"`
	Finished   time.Time `json:"finished"`
	Latchkey   string    `json:"latchkey,omitempty"`
	MacOS      string    `json:"macos,omitempty"`
	ClaudeCode string    `json:"claude_code,omitempty"`
	Model      string    `json:"model,omitempty"`
	SetupOK    bool      `json:"setup_ok"`
	// MissingPermissions: the test Mac image lost a permission (FR-1513); then no task ran.
	MissingPermissions []string      `json:"missing_permissions,omitempty"`
	Setup              string        `json:"setup_error,omitempty"`
	Checks             []CheckResult `json:"checks,omitempty"`
	Tasks              []TaskResult  `json:"tasks,omitempty"`
	// NotRun: tasks the one-hour cap left out (FR-1515).
	NotRun []string `json:"not_run,omitempty"`
	// RowsUnreachable: conditions no test here can produce (FR-1541).
	RowsUnreachable []string `json:"rows_unreachable"`
	// MAC proves a sent part came from someone holding the developer's private key: anyone can
	// seal to the public key and post to the intake, so an unsigned "result" could hide the
	// weekly reminder or plant failures (security review, 2026-11-24). See Sign.
	MAC string `json:"mac,omitempty"`
}

// SignKey derives the key that signs sent results from the developer's private key (its base64
// text): only the developer's own Mac and sessions hold it.
func SignKey(developerPrivate string) []byte {
	h := sha256.Sum256([]byte("latchkey-eval-sign-v1\x00" + strings.TrimSpace(developerPrivate)))
	return h[:]
}

func (r Result) mac(key []byte) (string, error) {
	r.MAC = ""
	b, err := json.Marshal(r)
	if err != nil {
		return "", err
	}
	m := hmac.New(sha256.New, key)
	m.Write(b)
	return base64.StdEncoding.EncodeToString(m.Sum(nil)), nil
}

// Sign sets the part's MAC.
func (r *Result) Sign(key []byte) error {
	m, err := r.mac(key)
	r.MAC = m
	return err
}

// Verify says whether the part's MAC is right.
func (r Result) Verify(key []byte) bool {
	want, err := r.mac(key)
	return err == nil && r.MAC != "" && hmac.Equal([]byte(want), []byte(r.MAC))
}

// CheckResult is one scripted end-to-end check of the run (FR-1516).
type CheckResult struct {
	Capability string `json:"capability"`
	Result     string `json:"result"` // passed, failed, skipped
	Why        string `json:"why,omitempty"`
}

// Unreachable is what the test Mac can't be (FR-1541).
var Unreachable = []string{
	"the owner's Mac locked", "the lid closed", "real iMessage and iCloud", "real websites",
	"the owner's own accounts and data",
}

// Summary counts a result's tasks.
type Summary struct {
	Tasks, PassAll, PassAny, Flaky, HeldOut, HeldOutPassAll, ChecksFailed int
}

// Summarize counts the tasks and checks.
func (r Result) Summarize() Summary {
	var s Summary
	for _, t := range r.Tasks {
		s.Tasks++
		if t.PassAll {
			s.PassAll++
		}
		if t.PassAny {
			s.PassAny++
		}
		if t.Flaky() {
			s.Flaky++
		}
		if t.HeldOut {
			s.HeldOut++
			if t.PassAll {
				s.HeldOutPassAll++
			}
		}
	}
	for _, c := range r.Checks {
		if c.Result == "failed" {
			s.ChecksFailed++
		}
	}
	return s
}

// SealParts seals a result to the developer's key in as many parts as it takes to keep each
// under the intake's limit (research.md decision 3): the checks go with part 1, the tasks are
// shared out in order; each part signed with signKey (SignKey).
func SealParts(pk hpke.PublicKey, signKey []byte, r Result) ([][]byte, error) {
	for n := 1; n <= 64; n *= 2 {
		parts, err := sealIn(pk, signKey, r, n)
		if err == nil {
			return parts, nil
		}
		if !errors.Is(err, errTooLong) {
			return nil, err
		}
	}
	return nil, errors.New("the result doesn't fit the intake even in 64 parts")
}

var errTooLong = errors.New("too long")

func sealIn(pk hpke.PublicKey, signKey []byte, r Result, n int) ([][]byte, error) {
	if n > 1 && n > len(r.Tasks) {
		return nil, errTooLong
	}
	per := (len(r.Tasks) + n - 1) / max(n, 1)
	var out [][]byte
	for i := range n {
		p := r
		p.Part, p.Parts = i+1, n
		lo, hi := min(i*per, len(r.Tasks)), min((i+1)*per, len(r.Tasks))
		p.Tasks = r.Tasks[lo:hi]
		if i > 0 {
			p.Checks, p.NotRun = nil, nil
		}
		if err := p.Sign(signKey); err != nil {
			return nil, err
		}
		plain, err := json.Marshal(p)
		if err != nil {
			return nil, err
		}
		sealed, err := reports.SealRaw(pk, plain)
		if err != nil {
			return nil, errTooLong
		}
		out = append(out, sealed)
	}
	return out, nil
}

// Join puts a run's parts back together: each part signed with signKey, numbered once from 1 to
// Parts, all agreeing on the run, and started no later than now.
func Join(parts []Result, signKey []byte, now time.Time) (Result, error) {
	if len(parts) == 0 {
		return Result{}, errors.New("no parts")
	}
	sort.Slice(parts, func(i, j int) bool { return parts[i].Part < parts[j].Part })
	r := parts[0]
	for i, p := range parts {
		switch {
		case !p.Verify(signKey):
			return r, fmt.Errorf("part %d isn't signed with the developer's key: not a result of ours, ignored", p.Part)
		case p.Part != i+1 || p.Parts != r.Parts || p.Run != r.Run || !p.Started.Equal(r.Started) || p.Latchkey != r.Latchkey:
			return r, errors.New("the run's parts don't agree (numbering, run, start or version)")
		}
	}
	if r.Started.After(now.Add(time.Hour)) {
		return r, errors.New("the run says it started in the future")
	}
	if len(parts) != r.Parts {
		return r, errors.New("some parts of the run haven't arrived")
	}
	r.Tasks = nil
	for _, p := range parts {
		r.Tasks = append(r.Tasks, p.Tasks...)
	}
	r.Part, r.Parts, r.MAC = 1, 1, ""
	return r, nil
}

// Comparison is this run against the one before (FR-1531).
type Comparison struct {
	NewFailures []string `json:"new_failures"`
	Fixed       []string `json:"fixed"`
	Flaky       []string `json:"flaky"`
	New         []string `json:"new_tasks"`
}

// Compare compares a run with the previous one (nil: none).
func Compare(prev *Result, cur Result) Comparison {
	c := Comparison{NewFailures: []string{}, Fixed: []string{}, Flaky: []string{}, New: []string{}}
	before := map[string]TaskResult{}
	if prev != nil {
		for _, t := range prev.Tasks {
			before[t.ID] = t
		}
	}
	for _, t := range cur.Tasks {
		if t.Flaky() {
			c.Flaky = append(c.Flaky, t.ID)
		}
		b, ok := before[t.ID]
		switch {
		case !ok:
			c.New = append(c.New, t.ID)
		case b.PassAll && !t.PassAny:
			c.NewFailures = append(c.NewFailures, t.ID)
		case !b.PassAll && t.PassAll:
			c.Fixed = append(c.Fixed, t.ID)
		}
	}
	return c
}
