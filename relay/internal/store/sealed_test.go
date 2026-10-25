package store_test

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"database/sql"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/store"
)

var secret = []byte("0123456789abcdef0123456789abcdef") // a 32-byte signing key, as the relay makes them

func fixed(v []byte) func() ([]byte, error) { return func() ([]byte, error) { return v, nil } }

// raw opens the database file directly, the way a thief with a copy of it would.
func raw(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

type keyRow struct {
	format int
	value  []byte
}

func keyRows(t *testing.T, path string) map[string]keyRow {
	t.Helper()
	rows, err := raw(t, path).QueryContext(context.Background(), `SELECT name, format, value FROM relay_keys`)
	require.NoError(t, err)
	defer func() { _ = rows.Close() }()
	out := map[string]keyRow{}
	for rows.Next() {
		var name string
		var r keyRow
		require.NoError(t, rows.Scan(&name, &r.format, &r.value))
		out[name] = r
	}
	require.NoError(t, rows.Err())
	return out
}

// sealedDB is a database with one sealed key, closed, and the paths of its files.
func sealedDB(t *testing.T) (db, keyFile string) {
	t.Helper()
	dir := t.TempDir()
	db, keyFile = filepath.Join(dir, "relay.db"), filepath.Join(dir, "relay.key")
	s, err := store.OpenWithKeyFile(context.Background(), db, keyFile)
	require.NoError(t, err)
	_, err = s.KeyOrCreate(context.Background(), "oauth_hmac", fixed(secret))
	require.NoError(t, err)
	require.NoError(t, s.Close())
	return db, keyFile
}

// A key is stored sealed, never as it is, and reads back the same after a restart (FR-186).
func TestStoredKeyIsSealedAndReadsBack(t *testing.T) {
	ctx := context.Background()
	db, keyFile := sealedDB(t)
	row := keyRows(t, db)["oauth_hmac"]
	assert.Equal(t, 1, row.format, "the stored form carries its version")
	assert.NotContains(t, string(row.value), string(secret))
	assert.Len(t, row.value, 12+len(secret)+16, "nonce, ciphertext, tag")
	file, err := os.ReadFile(filepath.Join(filepath.Dir(db), "relay.db"))
	require.NoError(t, err)
	assert.False(t, bytes.Contains(file, secret), "the database file doesn't hold the key")

	s, err := store.OpenWithKeyFile(ctx, db, keyFile)
	require.NoError(t, err)
	defer func() { _ = s.Close() }()
	got, err := s.KeyOrCreate(ctx, "oauth_hmac", fixed([]byte("another")))
	require.NoError(t, err)
	assert.Equal(t, secret, got)
	_, created := s.KeyFileCreated()
	assert.False(t, created, "the key file was already there")
}

// The same value sealed twice differs (a random nonce each time), and a value can't be moved to
// another row (the name is authenticated).
func TestSealingIsRandomizedAndBoundToTheName(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	db, keyFile := filepath.Join(dir, "relay.db"), filepath.Join(dir, "relay.key")
	s, err := store.OpenWithKeyFile(ctx, db, keyFile)
	require.NoError(t, err)
	for _, name := range []string{"oauth_hmac", "csrf"} {
		_, err = s.KeyOrCreate(ctx, name, fixed(secret))
		require.NoError(t, err)
	}
	require.NoError(t, s.Close())
	rows := keyRows(t, db)
	assert.NotEqual(t, rows["oauth_hmac"].value, rows["csrf"].value)

	_, err = raw(t, db).ExecContext(ctx, `UPDATE relay_keys SET value = (SELECT value FROM relay_keys WHERE name = 'csrf') WHERE name = 'oauth_hmac'`)
	require.NoError(t, err)
	_, err = store.OpenWithKeyFile(ctx, db, keyFile)
	require.ErrorIs(t, err, store.ErrKeys, "a value copied to another row doesn't open")
}

// The first start creates the key file: 32 bytes, for the relay's user only (FR-187).
func TestFirstStartCreatesTheKeyFile(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	keyFile := filepath.Join(dir, "relay.key")
	s, err := store.Open(ctx, filepath.Join(dir, "relay.db")) // the default place: next to the database
	require.NoError(t, err)
	defer func() { _ = s.Close() }()
	path, created := s.KeyFileCreated()
	assert.True(t, created)
	assert.Equal(t, keyFile, path)
	info, err := os.Stat(keyFile)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	assert.EqualValues(t, 32, info.Size())

	// Its folder must exist: the relay doesn't make folders for a key.
	_, err = store.OpenWithKeyFile(ctx, filepath.Join(t.TempDir(), "relay.db"), filepath.Join(dir, "missing", "relay.key"))
	require.ErrorIs(t, err, store.ErrKeys)
	assert.Contains(t, err.Error(), "missing")
}

// A key file others can read, or of the wrong size, is refused (FR-187).
func TestKeyFileThatIsTooOpenOrTheWrongSizeIsRefused(t *testing.T) {
	ctx := context.Background()
	for _, mode := range []os.FileMode{0o640, 0o604, 0o660, 0o644} {
		db, keyFile := sealedDB(t)
		require.NoError(t, os.Chmod(keyFile, mode))
		_, err := store.OpenWithKeyFile(ctx, db, keyFile)
		require.ErrorIs(t, err, store.ErrKeys, mode.String())
		assert.Contains(t, err.Error(), "chmod 600")
	}
	db, keyFile := sealedDB(t)
	require.NoError(t, os.WriteFile(keyFile, []byte("too short"), 0o600))
	_, err := store.OpenWithKeyFile(ctx, db, keyFile)
	require.ErrorIs(t, err, store.ErrKeys)
	assert.Contains(t, err.Error(), "32 bytes")

	db, keyFile = sealedDB(t)
	require.NoError(t, os.Remove(keyFile))
	require.NoError(t, os.Mkdir(keyFile, 0o700))
	_, err = store.OpenWithKeyFile(ctx, db, keyFile)
	require.ErrorIs(t, err, store.ErrKeys, "not a file")
}

func assertSaysBothWaysOut(t *testing.T, err error, keyFile string) {
	t.Helper()
	require.ErrorIs(t, err, store.ErrKeys)
	msg := err.Error()
	assert.Contains(t, msg, keyFile)
	assert.Contains(t, msg, "put the key file back")
	assert.Contains(t, msg, "reset-keys --confirm")
	assert.Contains(t, msg, "signs everyone out")
	assert.NotContains(t, msg, string(secret))
}

// Sealed keys without their key file: the relay refuses to start, says why and the two ways
// out, and neither makes a new key file nor touches the rows (FR-189).
func TestMissingKeyFileWithSealedKeysRefusesToStart(t *testing.T) {
	ctx := context.Background()
	db, keyFile := sealedDB(t)
	before := keyRows(t, db)
	require.NoError(t, os.Remove(keyFile))
	_, err := store.OpenWithKeyFile(ctx, db, keyFile)
	assertSaysBothWaysOut(t, err, keyFile)
	assert.Contains(t, err.Error(), "is missing")
	assert.NoFileExists(t, keyFile, "no new key is made by itself")
	assert.Equal(t, before, keyRows(t, db))
}

func TestWrongKeyFileRefusesToStart(t *testing.T) {
	ctx := context.Background()
	db, keyFile := sealedDB(t)
	before := keyRows(t, db)
	require.NoError(t, os.WriteFile(keyFile, bytes.Repeat([]byte{7}, 32), 0o600))
	_, err := store.OpenWithKeyFile(ctx, db, keyFile)
	assertSaysBothWaysOut(t, err, keyFile)
	assert.Contains(t, err.Error(), "does not open")
	assert.Equal(t, before, keyRows(t, db))
}

func TestTamperedKeyRowRefusesToStart(t *testing.T) {
	ctx := context.Background()
	db, keyFile := sealedDB(t)
	v := keyRows(t, db)["oauth_hmac"].value
	v[len(v)-1] ^= 1
	_, err := raw(t, db).ExecContext(ctx, `UPDATE relay_keys SET value = ? WHERE name = 'oauth_hmac'`, v)
	require.NoError(t, err)
	_, err = store.OpenWithKeyFile(ctx, db, keyFile)
	assertSaysBothWaysOut(t, err, keyFile)

	// A form from a newer version is not guessed at.
	db, keyFile = sealedDB(t)
	_, err = raw(t, db).ExecContext(ctx, `UPDATE relay_keys SET format = 2`)
	require.NoError(t, err)
	_, err = store.OpenWithKeyFile(ctx, db, keyFile)
	require.ErrorIs(t, err, store.ErrKeys)
	assert.Contains(t, err.Error(), "newer version")
}

// unseal turns a database back into what an earlier version wrote: keys as they are, no key
// file. It opens the sealed values itself, so it also pins the stored form: AES-256-GCM, a
// 12-byte nonce in front, the row's name as additional data.
func unseal(t *testing.T, db, keyFile string) map[string][]byte {
	t.Helper()
	ctx := context.Background()
	key, err := os.ReadFile(keyFile)
	require.NoError(t, err)
	block, err := aes.NewCipher(key)
	require.NoError(t, err)
	aead, err := cipher.NewGCM(block)
	require.NoError(t, err)
	plain := map[string][]byte{}
	for name, row := range keyRows(t, db) {
		require.Equal(t, 1, row.format)
		v, err := aead.Open(nil, row.value[:12], row.value[12:], []byte(name))
		require.NoError(t, err)
		plain[name] = v
		_, err = raw(t, db).ExecContext(ctx, `UPDATE relay_keys SET value = ?, format = 0 WHERE name = ?`, v, name)
		require.NoError(t, err)
	}
	require.NoError(t, os.Remove(keyFile))
	return plain
}

// A database from an earlier version is converted on the first start: every key sealed, the
// same values read back (FR-188).
func TestPlainKeysAreConvertedOnStart(t *testing.T) {
	ctx := context.Background()
	db, keyFile := sealedDB(t)
	plain := unseal(t, db, keyFile)
	require.Equal(t, secret, plain["oauth_hmac"])
	require.Equal(t, 0, keyRows(t, db)["oauth_hmac"].format)

	s, err := store.OpenWithKeyFile(ctx, db, keyFile)
	require.NoError(t, err)
	_, created := s.KeyFileCreated()
	assert.True(t, created)
	got, err := s.KeyOrCreate(ctx, "oauth_hmac", fixed([]byte("another")))
	require.NoError(t, err)
	assert.Equal(t, secret, got, "the key itself is unchanged")
	require.NoError(t, s.Close())
	row := keyRows(t, db)["oauth_hmac"]
	assert.Equal(t, 1, row.format)
	assert.NotContains(t, string(row.value), string(secret))
	for _, f := range []string{db, db + "-wal"} {
		if file, err := os.ReadFile(f); err == nil {
			assert.False(t, bytes.Contains(file, secret), "no trace of the old value in %s", filepath.Base(f))
		}
	}
}

// A conversion that can't finish changes nothing: with plain and sealed rows mixed and the wrong
// key file, the plain rows stay as they were (FR-188, FR-189).
func TestConversionIsAllOrNothing(t *testing.T) {
	ctx := context.Background()
	db, keyFile := sealedDB(t)
	_, err := raw(t, db).ExecContext(ctx, `INSERT INTO relay_keys (name, value, format) VALUES ('csrf', ?, 0)`, secret)
	require.NoError(t, err)
	before := keyRows(t, db)
	require.NoError(t, os.WriteFile(keyFile, bytes.Repeat([]byte{7}, 32), 0o600))
	_, err = store.OpenWithKeyFile(ctx, db, keyFile)
	require.ErrorIs(t, err, store.ErrKeys)
	assert.Equal(t, before, keyRows(t, db))
}

// The operator's way out when the key file is lost: the stored keys, every code and token, and
// every browser session go; accounts, passkeys, and paired Macs stay (FR-189).
func TestResetKeys(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	db, keyFile := filepath.Join(dir, "relay.db"), filepath.Join(dir, "relay.key")
	s, err := store.OpenWithKeyFile(ctx, db, keyFile)
	require.NoError(t, err)
	_, err = s.KeyOrCreate(ctx, "oauth_hmac", fixed(secret))
	require.NoError(t, err)
	u := newUser(t, s)
	d := newDevice(t, s, u.ID)
	require.NoError(t, s.AddPasskey(ctx, u.ID, []byte("cred"), []byte(`{}`), t0))
	require.NoError(t, s.CreateSession(ctx, []byte("session-hash"), u.ID, t0, t0.AddDate(1, 0, 0)))
	require.NoError(t, s.PutOAuthRequest(ctx, store.OAuthRequest{
		Signature: "sig", Kind: store.KindCode, RequestID: "r1", ClientID: "c1", UserID: u.ID,
		RequestedAt: t0, SessionJSON: []byte(`{}`), ExpiresAt: t0.AddDate(1, 0, 0),
	}))
	require.NoError(t, s.Close())
	require.NoError(t, os.Remove(keyFile))
	_, err = store.OpenWithKeyFile(ctx, db, keyFile)
	require.ErrorIs(t, err, store.ErrKeys)

	require.NoError(t, store.ResetKeys(ctx, db))
	assert.Empty(t, keyRows(t, db))

	s, err = store.OpenWithKeyFile(ctx, db, keyFile)
	require.NoError(t, err, "the relay starts again")
	defer func() { _ = s.Close() }()
	_, created := s.KeyFileCreated()
	assert.True(t, created, "with a new key file")
	fresh, err := s.KeyOrCreate(ctx, "oauth_hmac", fixed([]byte("a new signing key, 32 bytes long")))
	require.NoError(t, err)
	assert.NotEqual(t, secret, fresh)
	_, err = s.Session(ctx, []byte("session-hash"), t0)
	require.ErrorIs(t, err, store.ErrNotFound, "everyone is signed out")
	_, err = s.OAuthRequest(ctx, store.KindCode, "sig")
	require.ErrorIs(t, err, store.ErrNotFound, "Claude is disconnected")
	_, err = s.User(ctx, u.ID)
	require.NoError(t, err, "the account stays")
	keys, err := s.Passkeys(ctx, u.ID)
	require.NoError(t, err)
	assert.Len(t, keys, 1, "the passkey stays")
	got, err := s.ActiveDevice(ctx, u.ID)
	require.NoError(t, err)
	assert.Equal(t, d.ID, got.ID, "the Mac stays paired")
}
