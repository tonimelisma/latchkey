package account_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"testing"

	"github.com/fxamacker/cbor/v2"
	"github.com/stretchr/testify/require"
)

// softAuthenticator is a minimal platform authenticator: one discoverable P-256 credential per
// relying party, user verification always performed, "none" attestation.
type softAuthenticator struct {
	creds map[string]*softCred // by base64url credential ID
}

type softCred struct {
	id         []byte
	key        *ecdsa.PrivateKey
	userHandle []byte
	rpID       string
	signCount  uint32
}

func newSoftAuthenticator() *softAuthenticator {
	return &softAuthenticator{creds: map[string]*softCred{}}
}

var b64 = base64.RawURLEncoding

const (
	flagUP = 0x01
	flagUV = 0x04
	flagAT = 0x40
)

func authData(rpID string, flags byte, count uint32, attested []byte) []byte {
	h := sha256.Sum256([]byte(rpID))
	out := append([]byte{}, h[:]...)
	out = append(out, flags)
	out = binary.BigEndian.AppendUint32(out, count)
	return append(out, attested...)
}

func clientData(t *testing.T, typ, challenge, origin string) []byte {
	t.Helper()
	data, err := json.Marshal(map[string]any{"type": typ, "challenge": challenge, "origin": origin, "crossOrigin": false})
	require.NoError(t, err)
	return data
}

// create answers navigator.credentials.create for the options in begin.
func (a *softAuthenticator) create(t *testing.T, options map[string]any, origin string) map[string]any {
	t.Helper()
	pk := options["publicKey"].(map[string]any)
	rp := pk["rp"].(map[string]any)
	user := pk["user"].(map[string]any)
	userHandle, err := b64.DecodeString(user["id"].(string))
	require.NoError(t, err)

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	id := make([]byte, 16)
	_, _ = rand.Read(id)
	c := &softCred{id: id, key: key, userHandle: userHandle, rpID: rp["id"].(string)}
	a.creds[b64.EncodeToString(id)] = c

	x, y := key.X.FillBytes(make([]byte, 32)), key.Y.FillBytes(make([]byte, 32))
	cose, err := cbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: x, -3: y})
	require.NoError(t, err)
	attested := make([]byte, 16) // AAGUID
	attested = binary.BigEndian.AppendUint16(attested, uint16(len(id)))
	attested = append(attested, id...)
	attested = append(attested, cose...)
	ad := authData(c.rpID, flagUP|flagUV|flagAT, 0, attested)
	att, err := cbor.Marshal(map[string]any{"fmt": "none", "attStmt": map[string]any{}, "authData": ad})
	require.NoError(t, err)

	return map[string]any{
		"id": b64.EncodeToString(id), "rawId": b64.EncodeToString(id), "type": "public-key",
		"clientExtensionResults": map[string]any{}, "authenticatorAttachment": "platform",
		"response": map[string]any{
			"clientDataJSON":    b64.EncodeToString(clientData(t, "webauthn.create", pk["challenge"].(string), origin)),
			"attestationObject": b64.EncodeToString(att),
			"transports":        []string{"internal"},
		},
	}
}

// get answers navigator.credentials.get with the given credential (discoverable: any of ours).
func (a *softAuthenticator) get(t *testing.T, options map[string]any, origin string, c *softCred) map[string]any {
	t.Helper()
	pk := options["publicKey"].(map[string]any)
	c.signCount++
	ad := authData(c.rpID, flagUP|flagUV, c.signCount, nil)
	cd := clientData(t, "webauthn.get", pk["challenge"].(string), origin)
	h := sha256.Sum256(cd)
	digest := sha256.Sum256(append(append([]byte{}, ad...), h[:]...))
	sig, err := ecdsa.SignASN1(rand.Reader, c.key, digest[:])
	require.NoError(t, err)
	return map[string]any{
		"id": b64.EncodeToString(c.id), "rawId": b64.EncodeToString(c.id), "type": "public-key",
		"clientExtensionResults": map[string]any{}, "authenticatorAttachment": "platform",
		"response": map[string]any{
			"clientDataJSON":    b64.EncodeToString(cd),
			"authenticatorData": b64.EncodeToString(ad),
			"signature":         b64.EncodeToString(sig),
			"userHandle":        b64.EncodeToString(c.userHandle),
		},
	}
}

func (a *softAuthenticator) only(t *testing.T) *softCred {
	t.Helper()
	require.Len(t, a.creds, 1)
	for _, c := range a.creds {
		return c
	}
	return nil
}
