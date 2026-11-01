// Package devicekey keeps the server's P-256 device key: made at pairing, in a file only the
// Owner's account can read (plan D8; a TPM was weighed and left out in research.md), and used to
// sign the relay's challenge.
package devicekey

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Key is the device key.
type Key struct{ priv *ecdsa.PrivateKey }

// New makes a key in memory; Save writes it.
func New() (*Key, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	return &Key{priv}, nil
}

// Load reads the key file. A missing file is os.ErrNotExist. A file others can read is refused.
func Load(path string) (*Key, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("%s can be read by other users (mode %o); it must be 600", path, info.Mode().Perm())
	}
	der, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	k, err := x509.ParsePKCS8PrivateKey(der)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	priv, ok := k.(*ecdsa.PrivateKey)
	if !ok || priv.Curve != elliptic.P256() {
		return nil, errors.New(path + " is not a P-256 key")
	}
	return &Key{priv}, nil
}

// Save writes the key, readable only by the Owner.
func (k *Key) Save(path string) error {
	der, err := x509.MarshalPKCS8PrivateKey(k.priv)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return config.WriteAtomic(path, der, 0o600)
}

// PublicKey is the public key as PKIX DER, base64url without padding, as pairing sends it.
func (k *Key) PublicKey() string {
	der, err := x509.MarshalPKIXPublicKey(&k.priv.PublicKey)
	if err != nil {
		panic(err) // a P-256 key always marshals
	}
	return base64.RawURLEncoding.EncodeToString(der)
}

// Sign answers the relay's challenge (agent-protocol.md, Handshake).
func (k *Key) Sign(nonce, deviceID string) (string, error) {
	digest := sha256.Sum256(agentproto.SignatureInput(nonce, deviceID))
	sig, err := ecdsa.SignASN1(rand.Reader, k.priv, digest[:])
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(sig), nil
}
