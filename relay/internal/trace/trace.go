// Package trace keeps each account's full trace in daily files on the relay (spec 001 FR-680,
// FR-681, FR-683 to FR-687; contracts/trace-files.md): every tool call the relay answers, with
// its arguments and its whole result, and the account's events, one sealed line each, in
// <dir>/<account id>/YYYY-MM-DD.trace. Files are only ever appended to; nothing here renames,
// rewrites, or truncates one, and only Delete (the account's deletion) removes them.
//
// Writing never fails or holds up what is traced beyond one append and fsync: an error is
// logged and the call or event goes on as before. While the disk is low, nothing is written.
package trace

import (
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// KeyInfo is the HKDF info that derives the trace key from the relay's key file.
const KeyInfo = "latchkey relay traces v1"

const (
	// Version is the format version of the lines this version writes, outside and inside.
	Version = 1
	// Source names the relay in an export line.
	Source = "relay"
	// KindAction is a tool call's line, KindEvent an event's.
	KindAction = "action"
	KindEvent  = "event"

	// DefaultMinFree is the free space below which nothing is written (FR-684).
	DefaultMinFree uint64 = 2 << 30
	// DefaultCheckEvery is how long an answer about free space is kept.
	DefaultCheckEvery = 10 * time.Second

	// DayFormat names a day's file, in UTC.
	DayFormat  = "2006-01-02"
	timeFormat = "2006-01-02T15:04:05.000Z07:00"
	suffix     = ".trace"
)

// Line is the export line every side writes (contracts/trace-files.md, "The export line"),
// fields in the contract's order. The relay seals it without Account; the export adds it.
type Line struct {
	V          int             `json:"v"`
	Source     string          `json:"source"`
	Machine    string          `json:"-"`
	Time       string          `json:"time"`
	Kind       string          `json:"kind"`
	Tool       string          `json:"tool"`
	Arguments  json.RawMessage `json:"arguments"`
	Result     json.RawMessage `json:"result"`
	IsError    bool            `json:"isError"`
	DurationMS int64           `json:"durationMS"`
	CallID     string          `json:"-"`
	Client     string          `json:"-"`
	Outcome    string          `json:"outcome,omitempty"`
	// Session is the connector session the call came in on (spec 014 FR-1441), "" when the
	// client has none; lines from before 2026-11-25 have none.
	Session string `json:"-"`
	Account string `json:"account,omitempty"`
}

// wire is Line as written: machine, call_id, and client are null when empty.
type wire struct {
	V          int             `json:"v"`
	Source     string          `json:"source"`
	Machine    *string         `json:"machine"`
	Time       string          `json:"time"`
	Kind       string          `json:"kind"`
	Tool       string          `json:"tool"`
	Arguments  json.RawMessage `json:"arguments"`
	Result     json.RawMessage `json:"result"`
	IsError    bool            `json:"isError"`
	DurationMS int64           `json:"durationMS"`
	CallID     *string         `json:"call_id"`
	Client     *string         `json:"client"`
	Outcome    string          `json:"outcome,omitempty"`
	Session    string          `json:"session,omitempty"`
	Account    string          `json:"account,omitempty"`
}

func orNull(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func (l Line) wire() wire {
	return wire{
		V: l.V, Source: l.Source, Machine: orNull(l.Machine), Time: l.Time, Kind: l.Kind, Tool: l.Tool,
		Arguments: orEmpty(l.Arguments), Result: orEmpty(l.Result), IsError: l.IsError, DurationMS: l.DurationMS,
		CallID: orNull(l.CallID), Client: orNull(l.Client), Outcome: l.Outcome, Session: l.Session, Account: l.Account,
	}
}

func (w wire) line() Line {
	return Line{
		V: w.V, Source: w.Source, Machine: deref(w.Machine), Time: w.Time, Kind: w.Kind, Tool: w.Tool,
		Arguments: w.Arguments, Result: w.Result, IsError: w.IsError, DurationMS: w.DurationMS,
		CallID: deref(w.CallID), Client: deref(w.Client), Outcome: w.Outcome, Session: w.Session, Account: w.Account,
	}
}

func orEmpty(r json.RawMessage) json.RawMessage {
	if len(r) == 0 {
		return json.RawMessage(`""`)
	}
	return r
}

// encode writes v as one line of JSON, without HTML escaping, so text stays as it came.
func encode(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	return enc.Encode(v)
}

// JSONOrString is raw as JSON when it is JSON, otherwise raw as a JSON string ("" when empty).
func JSONOrString(raw []byte) json.RawMessage {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) > 0 && json.Valid(trimmed) {
		var b bytes.Buffer
		if err := json.Compact(&b, trimmed); err == nil {
			return b.Bytes()
		}
	}
	return String(string(raw))
}

// Marshal is v as JSON, without HTML escaping.
func Marshal(v any) (json.RawMessage, error) {
	var b bytes.Buffer
	if err := encode(&b, v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

// String is s as a JSON string.
func String(s string) json.RawMessage {
	var b bytes.Buffer
	if err := encode(&b, s); err != nil {
		return json.RawMessage(`""`)
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n"))
}

// Event is an event's line: its kind as the tool, its detail as the result.
func Event(kind, detail, machine string) Line {
	return Line{Kind: KindEvent, Tool: kind, Arguments: String(""), Result: String(detail), Machine: machine}
}

// Options configures a Store.
type Options struct {
	Dir    string // <DATA_DIR>/traces
	Key    []byte // 32 bytes: HKDF-SHA256 of the key file, info KeyInfo
	Logger *slog.Logger
	Now    func() time.Time // default time.Now; used for the free-space check
	// MinFree is the free space below which nothing is written; default DefaultMinFree.
	MinFree uint64
	// FreeSpace is the free space of the file system holding dir; default statfs.
	FreeSpace func(dir string) (uint64, error)
	// CheckEvery is how long an answer of FreeSpace is kept; default DefaultCheckEvery.
	CheckEvery time.Duration
	// AccountExists says whether an account is still there: an account's folder is made only for
	// one that is, so a call that ends after its account's deletion leaves nothing. Nil: always.
	AccountExists func(accountID string) bool
}

// Store writes and reads the trace files. A nil Store traces nothing.
type Store struct {
	o    Options
	aead cipher.AEAD
	sync func(*os.File) error // a test counts the fsyncs

	mu    sync.Mutex
	locks map[string]*sync.Mutex // per account: one writer at a time, and Delete waits for it

	disk    sync.Mutex
	checked time.Time
	paused  bool
	notify  func(paused bool, free uint64)
}

// New opens the trace folder, making it (0700) if needed.
func New(o Options) (*Store, error) {
	if o.Dir == "" {
		return nil, errors.New("trace: no folder")
	}
	if len(o.Key) != 32 {
		return nil, errors.New("trace: the key must be 32 bytes")
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.MinFree == 0 {
		o.MinFree = DefaultMinFree
	}
	if o.FreeSpace == nil {
		o.FreeSpace = freeSpace
	}
	if o.CheckEvery <= 0 {
		o.CheckEvery = DefaultCheckEvery
	}
	block, err := aes.NewCipher(o.Key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(o.Dir, 0o700); err != nil {
		return nil, fmt.Errorf("trace: make the folder %s: %w", o.Dir, err)
	}
	if err := os.Chmod(o.Dir, 0o700); err != nil { //nolint:gosec // a folder: 0700 is the owner only
		return nil, fmt.Errorf("trace: make the folder %s private: %w", o.Dir, err)
	}
	return &Store{o: o, aead: aead, sync: (*os.File).Sync, locks: map[string]*sync.Mutex{}}, nil
}

// Dir is the trace folder.
func (s *Store) Dir() string { return s.o.Dir }

// OnPauseChange sets what is told when writing stops for low disk (paused) and when it starts
// again, with the free space found. It is called outside every lock of the Store, at most once
// per change. Set it before the Store is used.
func (s *Store) OnPauseChange(f func(paused bool, free uint64)) {
	if s != nil {
		s.notify = f
	}
}

// idRE is what the relay's IDs look like (store.newID): never a path of its own.
var idRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$`)

func checkID(id string) error {
	if !idRE.MatchString(id) {
		return errors.New("trace: not an account ID")
	}
	return nil
}

func (s *Store) lock(id string) *sync.Mutex {
	s.mu.Lock()
	defer s.mu.Unlock()
	l, ok := s.locks[id]
	if !ok {
		l = &sync.Mutex{}
		s.locks[id] = l
	}
	return l
}

// writable reports whether there is room to write, asking the file system at most every
// CheckEvery, and tells of a change.
func (s *Store) writable() bool {
	s.disk.Lock()
	now := s.o.Now()
	changed, free := false, uint64(0)
	if s.checked.IsZero() || now.Sub(s.checked) >= s.o.CheckEvery {
		s.checked = now
		f, err := s.o.FreeSpace(s.o.Dir)
		if err != nil {
			s.o.Logger.Warn("trace: couldn't read the free disk space; writing on", "err", err)
		} else if low := f < s.o.MinFree; low != s.paused {
			s.paused, changed, free = low, true, f
		}
	}
	paused, notify := s.paused, s.notify
	s.disk.Unlock()
	if changed && notify != nil {
		notify(paused, free)
	}
	return !paused
}

// Append records l for the account, filed under the UTC day of at (when the call began). It
// fills in the version, the source, and the time. It never fails: an error is logged.
func (s *Store) Append(accountID string, at time.Time, l Line) {
	if s == nil {
		return
	}
	if err := s.append(accountID, at, l); err != nil {
		s.o.Logger.Error("trace line not written", "user", accountID, "tool", l.Tool, "err", err)
	}
}

func (s *Store) append(accountID string, at time.Time, l Line) error {
	if err := checkID(accountID); err != nil {
		return err
	}
	if !s.writable() {
		return nil
	}
	at = at.UTC()
	day := at.Format(DayFormat)
	l.V, l.Source, l.Time, l.Account = Version, Source, at.Format(timeFormat), ""
	var inner bytes.Buffer
	if err := encode(&inner, l.wire()); err != nil {
		return err
	}
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	sealed := s.aead.Seal(nonce, nonce, bytes.TrimSuffix(inner.Bytes(), []byte("\n")), aad(accountID, day))
	var out bytes.Buffer
	if err := encode(&out, struct {
		V      int    `json:"v"`
		Sealed []byte `json:"sealed"`
	}{Version, sealed}); err != nil {
		return err
	}

	lock := s.lock(accountID)
	lock.Lock()
	defer lock.Unlock()
	dir := filepath.Join(s.o.Dir, accountID)
	created := false
	if _, err := os.Stat(dir); errors.Is(err, fs.ErrNotExist) {
		if !s.exists(accountID) {
			return nil // the account was deleted while this was under way
		}
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
		created = true
	} else if err != nil {
		return err
	}
	if err := s.write(filepath.Join(dir, day+suffix), out.Bytes()); err != nil {
		return err
	}
	if created && !s.exists(accountID) { // deleted by another process in the meantime
		return os.RemoveAll(dir)
	}
	return nil
}

func (s *Store) exists(accountID string) bool {
	return s.o.AccountExists == nil || s.o.AccountExists(accountID)
}

// write appends one line and synchronizes the file. A line cut short by a crash or a full disk
// is ended first, so the new line is whole; the file's folder is synchronized when the file is
// new, so the file itself survives a crash.
func (s *Store) write(path string, line []byte) (err error) {
	_, statErr := os.Stat(path)
	isNew := errors.Is(statErr, fs.ErrNotExist)
	// No O_CREATE on the folder: one removed by a deletion stays removed.
	f, err := os.OpenFile(path, os.O_RDWR|os.O_APPEND|os.O_CREATE, 0o600) //nolint:gosec // the relay's own folder, an ID checked above
	if err != nil {
		return err
	}
	defer func() {
		if cerr := f.Close(); err == nil {
			err = cerr
		}
	}()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if n := info.Size(); n > 0 {
		last := make([]byte, 1)
		if _, err := f.ReadAt(last, n-1); err != nil {
			return err
		}
		if last[0] != '\n' {
			line = append([]byte("\n"), line...)
		}
	}
	if _, err := f.Write(line); err != nil {
		return err
	}
	if err := s.sync(f); err != nil {
		return err
	}
	if isNew {
		return syncDir(filepath.Dir(path))
	}
	return nil
}

func syncDir(dir string) error {
	d, err := os.Open(dir) //nolint:gosec // the relay's own folder
	if err != nil {
		return err
	}
	err = d.Sync()
	if cerr := d.Close(); err == nil {
		err = cerr
	}
	return err
}

func aad(accountID, day string) []byte { return []byte(accountID + "/" + day) }

// Delete removes the account's traces (FR-687).
func (s *Store) Delete(accountID string) error {
	if s == nil {
		return nil
	}
	if err := checkID(accountID); err != nil {
		return err
	}
	lock := s.lock(accountID)
	lock.Lock()
	defer lock.Unlock()
	// The lock keeps out only this process's writers. The operator's delete runs in its own
	// process while the relay may still be writing a line it began before the account was gone
	// from the database (regression 2026-11-24: "directory not empty"): try again while the
	// folder keeps gaining files. Such a writer never makes the folder again (append checks the
	// account first), so this ends; within a deadline all the same (Constitution II).
	dir := filepath.Join(s.o.Dir, accountID)
	deadline := time.Now().Add(deleteLimit)
	for {
		err := os.RemoveAll(dir)
		if err == nil || !errors.Is(err, syscall.ENOTEMPTY) || time.Now().After(deadline) {
			return err
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// deleteLimit bounds Delete's tries while another process still writes the account's folder.
const deleteLimit = 5 * time.Second

var dayFileRE = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}\.trace$`)

// CheckDay reports whether d is a day as the files name them (YYYY-MM-DD); "" is no limit.
func CheckDay(d string) error {
	if d == "" {
		return nil
	}
	if t, err := time.Parse(DayFormat, d); err != nil || t.Format(DayFormat) != d {
		return fmt.Errorf("%q is not a day; write it as YYYY-MM-DD", d)
	}
	return nil
}

// Each calls fn with the account's lines from the day from to the day to (both included, ""
// for no limit), oldest first, and returns how many lines it skipped because they couldn't be
// read (cut short, another version, another key, moved). It never changes a file.
func (s *Store) Each(accountID, from, to string, fn func(Line) error) (skipped int, err error) {
	if s == nil {
		return 0, nil
	}
	if err := checkID(accountID); err != nil {
		return 0, err
	}
	if err := CheckDay(from); err != nil {
		return 0, err
	}
	if err := CheckDay(to); err != nil {
		return 0, err
	}
	dir := filepath.Join(s.o.Dir, accountID)
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	var days []string
	for _, e := range entries {
		name := e.Name()
		if !e.Type().IsRegular() || !dayFileRE.MatchString(name) {
			continue
		}
		day := strings.TrimSuffix(name, suffix)
		if (from != "" && day < from) || (to != "" && day > to) {
			continue
		}
		days = append(days, day)
	}
	slices.Sort(days)
	for _, day := range days {
		n, err := s.eachInDay(accountID, day, filepath.Join(dir, day+suffix), fn)
		skipped += n
		if err != nil {
			return skipped, err
		}
	}
	return skipped, nil
}

// eachInDay reads a day's file twice: first each line's time and place, then, in time order,
// each line again, so only one line is held at once however large the day.
func (s *Store) eachInDay(accountID, day, path string, fn func(Line) error) (skipped int, err error) {
	f, err := os.Open(path) //nolint:gosec // the relay's own folder, an ID checked above
	if err != nil {
		return 0, err
	}
	defer func() { _ = f.Close() }()
	type ref struct {
		at  time.Time
		off int64
		n   int
	}
	var refs []ref
	r := bufio.NewReaderSize(f, 64<<10)
	var off int64
	for {
		b, rerr := r.ReadBytes('\n')
		if len(bytes.TrimSpace(b)) > 0 {
			if l, ok := s.open(accountID, day, b); ok {
				at, _ := time.Parse(time.RFC3339Nano, l.Time)
				refs = append(refs, ref{at: at, off: off, n: len(b)})
			} else {
				skipped++
			}
		}
		off += int64(len(b))
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			return skipped, rerr
		}
	}
	sort.SliceStable(refs, func(i, j int) bool { return refs[i].at.Before(refs[j].at) })
	for _, rf := range refs {
		b := make([]byte, rf.n)
		if _, err := f.ReadAt(b, rf.off); err != nil {
			return skipped, err
		}
		l, ok := s.open(accountID, day, b)
		if !ok {
			skipped++
			continue
		}
		if err := fn(l); err != nil {
			return skipped, err
		}
	}
	return skipped, nil
}

// open reads one stored line; false when it can't be read.
func (s *Store) open(accountID, day string, b []byte) (Line, bool) {
	var outer struct {
		V      int    `json:"v"`
		Sealed []byte `json:"sealed"`
	}
	if json.Unmarshal(b, &outer) != nil || outer.V != Version {
		return Line{}, false
	}
	n := s.aead.NonceSize()
	if len(outer.Sealed) < n+s.aead.Overhead() {
		return Line{}, false
	}
	plain, err := s.aead.Open(nil, outer.Sealed[:n], outer.Sealed[n:], aad(accountID, day))
	if err != nil {
		return Line{}, false
	}
	var w wire
	if json.Unmarshal(plain, &w) != nil || w.V != Version {
		return Line{}, false
	}
	return w.line(), true
}

// Export writes the account's lines from from to to (as Each) to w, one export line each,
// with the account's address (contracts/trace-files.md, FR-685, FR-686).
func (s *Store) Export(accountID, email, from, to string, w io.Writer) (skipped int, err error) {
	bw := bufio.NewWriterSize(w, 64<<10)
	skipped, err = s.Each(accountID, from, to, func(l Line) error {
		l.Account = email
		return encode(bw, l.wire())
	})
	if ferr := bw.Flush(); err == nil {
		err = ferr
	}
	return skipped, err
}
