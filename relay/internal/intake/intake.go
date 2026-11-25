// Package intake is the developer's intake for problem reports (spec 014 FR-1420 to FR-1425):
// it takes sealed reports from any relay, with a proof of work and a limit per sender, and gives
// them to the developer, who holds the only key that opens them. The intake never can.
package intake

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	_ "modernc.org/sqlite" // the database driver

	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// Options configures the intake.
type Options struct {
	// DeveloperToken is the bearer token the developer's endpoints need.
	DeveloperToken string
	// PerHour is how many reports one sender address may deliver in an hour (FR-1421).
	PerHour int
	// MaxReports bounds how many reports wait at once, so the disk can't be filled.
	MaxReports int
	// BytesPerHour bounds what one sender address may deliver in an hour (FR-1456; default
	// 50 MB), and MaxBytes what all waiting reports may hold together (default 5 GB).
	BytesPerHour int64
	MaxBytes     int64
	// WorkBits is the proof of work's difficulty (reports.WorkBits by default).
	WorkBits int
	// TrustedProxies whose X-Forwarded-For names the sender (the reverse proxy in front).
	TrustedProxies limit.TrustedProxies
	Logger         *slog.Logger
	Now            func() time.Time
}

// MaxReading is how many report bodies the intake reads at once.
const MaxReading = 8

// Intake is the service.
type Intake struct {
	db    *sql.DB
	opts  Options
	token [32]byte
	rate  *limit.Keyed
	sent  byteCounts
	// reading bounds how many bodies are read at once (MaxReading).
	reading chan struct{}
}

// byteCounts counts the bytes each sender delivered in the current hour (FR-1456).
type byteCounts struct {
	mu   sync.Mutex
	hour string
	by   map[string]int64
}

// refund takes back bytes counted for a report that wasn't kept.
func (b *byteCounts) refund(sender, hour string, n int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.hour == hour && b.by != nil {
		b.by[sender] = max(0, b.by[sender]-n)
	}
}

// add counts n bytes for the sender, unless that would take it over max; it says whether it did.
func (b *byteCounts) add(sender, hour string, n, max int64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.hour != hour || b.by == nil {
		b.hour, b.by = hour, map[string]int64{}
	}
	if b.by[sender]+n > max {
		return false
	}
	b.by[sender] += n
	return true
}

// Open opens (or makes) the intake's database at path.
func Open(path string, o Options) (*Intake, error) {
	if len(o.DeveloperToken) < 32 {
		return nil, errors.New("the developer token must have at least 32 characters")
	}
	if o.PerHour <= 0 {
		o.PerHour = 60
	}
	if o.MaxReports <= 0 {
		o.MaxReports = 10_000
	}
	if o.BytesPerHour <= 0 {
		o.BytesPerHour = 50 << 20
	}
	if o.MaxBytes <= 0 {
		o.MaxBytes = 5 << 30
	}
	if o.WorkBits <= 0 {
		o.WorkBits = reports.WorkBits
	}
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.ExecContext(context.Background(), `CREATE TABLE IF NOT EXISTS reports (
		id      TEXT PRIMARY KEY,
		arrived INTEGER NOT NULL,
		sealed  BLOB NOT NULL
	) STRICT`); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Intake{
		db: db, opts: o, token: sha256.Sum256([]byte(o.DeveloperToken)),
		rate:    limit.NewKeyed(o.PerHour, time.Hour/time.Duration(o.PerHour)),
		reading: make(chan struct{}, MaxReading),
	}, nil
}

// Close closes the database.
func (in *Intake) Close() error { return in.db.Close() }

// Handler serves the intake's endpoints (contract feedback-intake.md).
func (in *Intake) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/reports", in.take)
	mux.HandleFunc("GET /v1/reports", in.developer(in.list))
	mux.HandleFunc("GET /v1/reports/{id}", in.developer(in.get))
	mux.HandleFunc("DELETE /v1/reports/{id}", in.developer(in.remove))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = io.WriteString(w, "ok\n") })
	return mux
}

// take accepts a sealed report from anyone: report-shaped, within the size limit, with a proof
// of work for this hour or the last, within the sender's limit (FR-1420, FR-1421).
func (in *Intake) take(w http.ResponseWriter, r *http.Request) {
	// What can be checked without the body comes first, so a sender over its limit or without a
	// proof for this hour never gets a 5 MB body into memory (security review 2026-11-25).
	if r.ContentLength > reports.MaxSealed {
		http.Error(w, "too large", http.StatusRequestEntityTooLarge)
		return
	}
	hour := r.Header.Get("Latchkey-Work-Hour")
	now := in.opts.Now()
	nonce, err := strconv.ParseUint(r.Header.Get("Latchkey-Work-Nonce"), 10, 64)
	if err != nil || (hour != reports.Hour(now) && hour != reports.Hour(now.Add(-time.Hour))) {
		http.Error(w, "no valid proof of work", http.StatusForbidden)
		return
	}
	sender := in.opts.TrustedProxies.ClientIP(r)
	if !in.rate.Allow(sender) {
		http.Error(w, "too many reports from this address", http.StatusTooManyRequests)
		return
	}
	select { // a few bodies at a time
	case in.reading <- struct{}{}:
		defer func() { <-in.reading }()
	default:
		http.Error(w, "busy; try later", http.StatusServiceUnavailable)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, reports.MaxSealed+1))
	if err != nil || len(body) > reports.MaxSealed {
		http.Error(w, "too large", http.StatusRequestEntityTooLarge)
		return
	}
	if !reports.Shaped(body) {
		http.Error(w, "not a sealed report", http.StatusBadRequest)
		return
	}
	if !reports.Proven(body, hour, nonce, in.opts.WorkBits) {
		http.Error(w, "no valid proof of work", http.StatusForbidden)
		return
	}
	if !in.sent.add(sender, reports.Hour(now), int64(len(body)), in.opts.BytesPerHour) {
		http.Error(w, "too many bytes from this address this hour", http.StatusTooManyRequests)
		return
	}
	var waiting int
	var held int64
	if err := in.db.QueryRowContext(r.Context(), `SELECT count(*), coalesce(sum(length(sealed)), 0) FROM reports`).Scan(&waiting, &held); err != nil {
		in.fail(w, err)
		return
	}
	if waiting >= in.opts.MaxReports || held+int64(len(body)) > in.opts.MaxBytes {
		in.sent.refund(sender, reports.Hour(now), int64(len(body)))
		http.Error(w, "the intake is full; try later", http.StatusServiceUnavailable)
		return
	}
	id := "rep_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err := in.db.ExecContext(r.Context(), `INSERT INTO reports (id, arrived, sealed) VALUES (?, ?, ?)`,
		id, now.UnixMilli(), body); err != nil {
		in.fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]string{"id": id})
}

// developer guards an endpoint with the developer's token (FR-1423).
func (in *Intake) developer(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		sum := sha256.Sum256([]byte(got))
		if !ok || subtle.ConstantTimeCompare(sum[:], in.token[:]) != 1 {
			http.Error(w, "the developer's token is needed", http.StatusUnauthorized)
			return
		}
		h(w, r)
	}
}

// Listed is one waiting report in the developer's list.
type Listed struct {
	ID      string    `json:"id"`
	Arrived time.Time `json:"arrived"`
}

func (in *Intake) list(w http.ResponseWriter, r *http.Request) {
	rows, err := in.db.QueryContext(r.Context(), `SELECT id, arrived FROM reports ORDER BY arrived, id`)
	if err != nil {
		in.fail(w, err)
		return
	}
	defer func() { _ = rows.Close() }()
	out := []Listed{}
	for rows.Next() {
		var l Listed
		var ms int64
		if err := rows.Scan(&l.ID, &ms); err != nil {
			in.fail(w, err)
			return
		}
		l.Arrived = time.UnixMilli(ms).UTC()
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		in.fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func (in *Intake) get(w http.ResponseWriter, r *http.Request) {
	var sealed []byte
	err := in.db.QueryRowContext(r.Context(), `SELECT sealed FROM reports WHERE id = ?`, r.PathValue("id")).Scan(&sealed)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "no such report", http.StatusNotFound)
		return
	}
	if err != nil {
		in.fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(sealed)
}

// remove deletes a dispositioned report, leaving nothing (FR-1424).
func (in *Intake) remove(w http.ResponseWriter, r *http.Request) {
	res, err := in.db.ExecContext(r.Context(), `DELETE FROM reports WHERE id = ?`, r.PathValue("id"))
	if err != nil {
		in.fail(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		http.Error(w, "no such report", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (in *Intake) fail(w http.ResponseWriter, err error) {
	in.opts.Logger.Error("intake", "err", err)
	http.Error(w, "the intake failed; try later", http.StatusInternalServerError)
}

// Waiting counts the reports waiting, for the log.
func (in *Intake) Waiting(ctx context.Context) (int, error) {
	var n int
	err := in.db.QueryRowContext(ctx, `SELECT count(*) FROM reports`).Scan(&n)
	return n, err
}
