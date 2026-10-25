package store

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"os"
)

// The relay's own signing keys (table relay_keys) are stored sealed under a key that lives in a
// separate file, so a copy of the database alone can't be used to forge tokens (FR-186 to
// FR-189, plan D10, Constitution VI).

// DefaultKeyFileName is the key file's name next to the database (the default KEY_FILE).
const DefaultKeyFileName = "relay.key"

const (
	keyFileSize = 32 // AES-256

	// The format column of relay_keys is the version of a stored value.
	formatPlain = 0 // as earlier versions wrote it: the key itself
	formatGCM   = 1 // AES-256-GCM: a 12-byte nonce, then ciphertext and tag; the row's name is the additional data
)

// ErrKeys means the relay's stored keys can't be used with the key file as it is. The relay
// must not start; the message says what happened and what the operator can do. It never holds
// key material.
var ErrKeys = errors.New("the relay's stored keys can't be used")

func keysErr(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrKeys, fmt.Sprintf(format, args...))
}

// waysOut is the end of every refusal about sealed keys that can't be opened.
func waysOut(keyFile string) string {
	return fmt.Sprintf("Two ways out: put the key file back at %s (or point KEY_FILE at where it is); "+
		"or delete the stored keys with `relay reset-keys --confirm` while the relay is stopped, which signs everyone out "+
		"and disconnects Claude, and keeps accounts, passkeys and paired Macs.", keyFile)
}

// OpenWithKeyFile opens (creating if needed) the database at path, applies pending migrations,
// and makes the relay's stored keys usable with the key file at keyFile: created on the first
// start, checked on every start, and used to seal keys an earlier version stored as they were.
// An error that is ErrKeys means the operator has to act.
func OpenWithKeyFile(ctx context.Context, path, keyFile string) (*Store, error) {
	s, err := openDB(ctx, path)
	if err != nil {
		return nil, err
	}
	if err := s.unlockKeys(ctx, keyFile); err != nil {
		_ = s.Close()
		return nil, err
	}
	return s, nil
}

// KeyFileCreated returns the key file's path and whether this start created it.
func (s *Store) KeyFileCreated() (string, bool) { return s.keyFile, s.keyFileCreated }

type storedKey struct {
	name   string
	format int
	value  []byte
}

func readKeys(ctx context.Context, q interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
},
) ([]storedKey, error) {
	rows, err := q.QueryContext(ctx, `SELECT name, format, value FROM relay_keys ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []storedKey
	for rows.Next() {
		var k storedKey
		if err := rows.Scan(&k.name, &k.format, &k.value); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

func (s *Store) unlockKeys(ctx context.Context, keyFile string) error {
	keys, err := readKeys(ctx, s.db)
	if err != nil {
		return err
	}
	sealed, plain := 0, 0
	for _, k := range keys {
		switch k.format {
		case formatPlain:
			plain++
		case formatGCM:
			sealed++
		default:
			return keysErr("the key %q is stored in a form (version %d) this version of the relay doesn't know; it was written by a newer version. Run that version, or a newer one.", k.name, k.format)
		}
	}
	key, created, err := loadKeyFile(keyFile, sealed > 0)
	if err != nil {
		return err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	s.aead, s.keyFile, s.keyFileCreated = aead, keyFile, created

	// Every sealed key must open before anything else is done with the key file.
	for _, k := range keys {
		if k.format != formatGCM {
			continue
		}
		if _, err := s.unseal(k.name, k.value); err != nil {
			return keysErr("the key file %s does not open the stored key %q: it is a different key file, or the database was altered. %s",
				keyFile, k.name, waysOut(keyFile))
		}
	}
	if plain == 0 {
		return nil
	}
	return s.sealPlainKeys(ctx)
}

// loadKeyFile reads the key file, or creates it when there is none and nothing depends on one.
func loadKeyFile(path string, sealedExist bool) (key []byte, created bool, err error) {
	info, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if sealedExist {
			return nil, false, keysErr("they are encrypted, and the key file %s is missing. %s", path, waysOut(path))
		}
		key, err = createKeyFile(path)
		return key, err == nil, err
	case err != nil:
		return nil, false, keysErr("the key file %s can't be read (%s). %s", path, reason(err), waysOut(path))
	case !info.Mode().IsRegular():
		return nil, false, keysErr("the key file %s is not a file. %s", path, waysOut(path))
	case info.Mode().Perm()&0o077 != 0:
		return nil, false, keysErr("the key file %s can be read by other users (mode %04o). Make it readable by the relay's user only: chmod 600 %s",
			path, info.Mode().Perm(), path)
	}
	key, err = os.ReadFile(path) //nolint:gosec // the operator's own setting
	if err != nil {
		return nil, false, keysErr("the key file %s can't be read (%s). %s", path, reason(err), waysOut(path))
	}
	if len(key) != keyFileSize {
		msg := "the key file %s is %d bytes; it must be exactly %d bytes. "
		if sealedExist {
			return nil, false, keysErr(msg+"%s", path, len(key), keyFileSize, waysOut(path))
		}
		return nil, false, keysErr(msg+"Nothing is encrypted with it yet: delete it and start the relay again to have a new one made.", path, len(key), keyFileSize)
	}
	return key, false, nil
}

// reason is the operating system's part of a file error, without the path (already named).
func reason(err error) string {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	return "unexpected error"
}

// createKeyFile makes a new key: never over an existing file, for the relay's user only, and on
// disk before anything is sealed with it.
func createKeyFile(path string) ([]byte, error) {
	key := make([]byte, keyFileSize)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600) //nolint:gosec // the operator's own setting
	if err != nil {
		return nil, keysErr("the key file %s can't be created (%s). Its folder must exist and be writable by the relay's user.", path, reason(err))
	}
	_, err = f.Write(key)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(path)
		return nil, keysErr("the key file %s couldn't be written (%s).", path, reason(err))
	}
	return key, nil
}

func (s *Store) seal(name string, value []byte) ([]byte, error) {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return s.aead.Seal(nonce, nonce, value, []byte(name)), nil
}

func (s *Store) unseal(name string, stored []byte) ([]byte, error) {
	n := s.aead.NonceSize()
	if len(stored) < n+s.aead.Overhead() {
		return nil, errors.New("stored key is too short")
	}
	return s.aead.Open(nil, stored[:n], stored[n:], []byte(name))
}

// sealPlainKeys converts keys an earlier version stored as they were, all or nothing: each new
// value is written, read back, opened and compared with the old one inside one transaction,
// which is rolled back if anything differs (FR-188). The old bytes are overwritten rather than
// left in free pages (secure_delete, then VACUUM and a truncated write-ahead log).
func (s *Store) sealPlainKeys(ctx context.Context) error {
	err := s.immediate(ctx, func(conn *sql.Conn) error {
		if _, err := conn.ExecContext(ctx, `PRAGMA secure_delete = ON`); err != nil {
			return err
		}
		keys, err := readKeys(ctx, conn)
		if err != nil {
			return err
		}
		for _, k := range keys {
			if k.format != formatPlain {
				continue
			}
			sealed, err := s.seal(k.name, k.value)
			if err != nil {
				return err
			}
			res, err := conn.ExecContext(ctx, `UPDATE relay_keys SET value = ?, format = ? WHERE name = ? AND format = ?`,
				sealed, formatGCM, k.name, formatPlain)
			if err != nil {
				return err
			}
			if err := requireOneRow(res); err != nil {
				return err
			}
			var back []byte
			if err := conn.QueryRowContext(ctx, `SELECT value FROM relay_keys WHERE name = ? AND format = ?`, k.name, formatGCM).Scan(&back); err != nil {
				return err
			}
			opened, err := s.unseal(k.name, back)
			if err != nil || subtle.ConstantTimeCompare(opened, k.value) != 1 {
				return keysErr("the key %q did not read back the same after encrypting it; nothing was changed.", k.name)
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, `VACUUM`); err != nil {
		return fmt.Errorf("clean up after encrypting the stored keys: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		return fmt.Errorf("clean up after encrypting the stored keys: %w", err)
	}
	return nil
}

// KeyOrCreate returns a server key, creating it with gen the first time. It is stored sealed.
func (s *Store) KeyOrCreate(ctx context.Context, name string, gen func() ([]byte, error)) ([]byte, error) {
	if s.aead == nil {
		return nil, errors.New("store: opened without a key file")
	}
	v, err := s.key(ctx, name)
	if !errors.Is(err, ErrNotFound) {
		return v, err
	}
	v, err = gen()
	if err != nil {
		return nil, err
	}
	sealed, err := s.seal(name, v)
	if err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `INSERT OR IGNORE INTO relay_keys (name, value, format) VALUES (?, ?, ?)`, name, sealed, formatGCM); err != nil {
		return nil, err
	}
	return s.key(ctx, name)
}

func (s *Store) key(ctx context.Context, name string) ([]byte, error) {
	var stored []byte
	var format int
	err := s.db.QueryRowContext(ctx, `SELECT value, format FROM relay_keys WHERE name = ?`, name).Scan(&stored, &format)
	if err != nil {
		return nil, mapErr(err)
	}
	if format != formatGCM {
		return nil, keysErr("the key %q is not stored in the encrypted form the relay wrote.", name)
	}
	v, err := s.unseal(name, stored)
	if err != nil {
		return nil, keysErr("the stored key %q no longer opens with the key file.", name)
	}
	return v, nil
}

// ResetKeys is the operator's way out when the key file is lost (FR-189): it deletes the
// relay's stored keys, and with them what they signed or protected: every OAuth code and token
// (Claude has to be connected again) and every browser session (everyone signs in again).
// Accounts, passkeys, paired Macs and everything else stay. The relay must not be running. The
// next start makes new keys, and a new key file if there is none.
func ResetKeys(ctx context.Context, path string) error {
	s, err := openDB(ctx, path)
	if err != nil {
		return err
	}
	defer func() { _ = s.Close() }()
	err = s.immediate(ctx, func(conn *sql.Conn) error {
		for _, q := range []string{
			`PRAGMA secure_delete = ON`,
			`DELETE FROM relay_keys`,
			`DELETE FROM oauth_requests`,
			`DELETE FROM web_sessions`,
		} {
			if _, err := conn.ExecContext(ctx, q); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `PRAGMA wal_checkpoint(TRUNCATE)`)
	return err
}
