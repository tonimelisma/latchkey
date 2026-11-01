package update

import (
	"crypto/ed25519"
	"encoding/base64"
)

// publicKey checks every server release (Toni, 2026-10-31: Latchkey's own Ed25519 key). Its
// private half is in the maintainer's gitignored .env (SERVER_SIGNING_KEY) and macOS keychain. A
// fork that publishes its own releases puts its own public key here and its repository in
// update_repo.
const publicKey = "qJGRlZxRgdjYHQ3q7ZmE2mWxJChr50XfGzwEGiWOHP8="

// PublicKey is the built-in release key.
func PublicKey() ed25519.PublicKey {
	k, err := base64.StdEncoding.DecodeString(publicKey)
	if err != nil || len(k) != ed25519.PublicKeySize {
		panic("update: the built-in public key is malformed")
	}
	return k
}
