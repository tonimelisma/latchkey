// Package store is the relay's SQLite database. Everything it holds is listed in
// specs/001-core/data-model.md (Constitution VI).
package store

import (
	"context"
	"crypto/cipher"
	"crypto/rand"
	"database/sql"
	"embed"
	"encoding/base32"
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"strings"
	"time"

	"github.com/pressly/goose/v3"
	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

//go:embed migrations/*.sql
var migrations embed.FS

var (
	// ErrNotFound means no matching row.
	ErrNotFound = errors.New("not found")
	// ErrConflict means a uniqueness rule was violated.
	ErrConflict = errors.New("conflict")
)

// Store wraps the database.
type Store struct {
	db *sql.DB
	// The relay's own keys are sealed with aead, made from the key file (sealed.go).
	aead           cipher.AEAD
	keyFile        string
	keyFileCreated bool
}

// Open opens (creating if needed) the database at path, with its key file next to it (see
// OpenWithKeyFile), and applies pending migrations.
func Open(ctx context.Context, path string) (*Store, error) {
	return OpenWithKeyFile(ctx, path, filepath.Join(filepath.Dir(path), DefaultKeyFileName))
}

// openDB opens the database and applies pending migrations; the stored keys are not usable yet.
func openDB(ctx context.Context, path string) (*Store, error) {
	dsn := "file:" + path + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	if err := migrate(ctx, db); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func migrate(ctx context.Context, db *sql.DB) error {
	dir, err := fs.Sub(migrations, "migrations")
	if err != nil {
		return err
	}
	p, err := goose.NewProvider(goose.DialectSQLite3, db, dir)
	if err != nil {
		return err
	}
	if _, err := p.Up(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	return nil
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// immediate runs fn in a BEGIN IMMEDIATE transaction: it takes the write lock before its first
// read, so concurrent callers run one after another and a check and the write that depends on
// it cannot be interleaved. fn's error rolls back.
func (s *Store) immediate(ctx context.Context, fn func(conn *sql.Conn) error) (err error) {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			// A fresh context: a cancelled request must not leave the transaction open.
			_, _ = conn.ExecContext(context.WithoutCancel(ctx), `ROLLBACK`)
		}
	}()
	if err = fn(conn); err != nil {
		return err
	}
	_, err = conn.ExecContext(ctx, `COMMIT`)
	return err
}

func newID(prefix string) string {
	b := make([]byte, 16)
	_, _ = rand.Read(b) // never fails (crypto/rand)
	return prefix + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
}

// toMS stores the zero time as NULL.
func toMS(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UnixMilli()
}

func fromMS(n sql.NullInt64) time.Time {
	if !n.Valid {
		return time.Time{}
	}
	return time.UnixMilli(n.Int64).UTC()
}

func nullString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullBytes(b []byte) any {
	if b == nil {
		return nil
	}
	return string(b)
}

func mapErr(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	var se *sqlite.Error
	if errors.As(err, &se) && se.Code() == sqlite3.SQLITE_CONSTRAINT_UNIQUE {
		return fmt.Errorf("%w: %w", ErrConflict, err)
	}
	return err
}

func requireOneRow(res sql.Result) error {
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
