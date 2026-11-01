package devicekey_test

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/devicekey"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

func TestKeySignsWhatTheRelayVerifies(t *testing.T) {
	path := filepath.Join(t.TempDir(), "data", "device.key")
	k, err := devicekey.New()
	require.NoError(t, err)
	require.NoError(t, k.Save(path))
	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	loaded, err := devicekey.Load(path)
	require.NoError(t, err)
	assert.Equal(t, k.PublicKey(), loaded.PublicKey())

	der, err := base64.RawURLEncoding.DecodeString(loaded.PublicKey())
	require.NoError(t, err)
	pub, err := x509.ParsePKIXPublicKey(der)
	require.NoError(t, err)
	nonce, err := agentproto.NewNonce()
	require.NoError(t, err)
	sig, err := loaded.Sign(nonce, "dev_1")
	require.NoError(t, err)
	require.NoError(t, agentproto.VerifySignature(pub.(*ecdsa.PublicKey), nonce, "dev_1", sig), "the relay's own check accepts it")
	require.Error(t, agentproto.VerifySignature(pub.(*ecdsa.PublicKey), nonce, "dev_2", sig))
}

func TestKeyFileMustBePrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "device.key")
	k, err := devicekey.New()
	require.NoError(t, err)
	require.NoError(t, k.Save(path))
	require.NoError(t, os.Chmod(path, 0o644))
	_, err = devicekey.Load(path)
	require.ErrorContains(t, err, "must be 600")
	_, err = devicekey.Load(filepath.Join(t.TempDir(), "missing"))
	require.ErrorIs(t, err, os.ErrNotExist)
}
