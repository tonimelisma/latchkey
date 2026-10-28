package oauth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"strings"
)

// Token formats. The relay's codes and tokens are opaque: a prefix naming the kind, 32 random
// bytes, and an HMAC-SHA512/256 of those bytes under the relay's oauth_hmac key, each part in
// unpadded base64url ("ory_at_<key>.<signature>"). Only the signature is stored, so a copy of
// the database holds no usable token. This is the format the relay has issued since its first
// version (fosite's prefixed HMAC strategy), kept byte for byte so that codes, access tokens and
// refresh tokens issued before the move to zitadel/oidc keep working (plan D4).
const (
	prefixCode    = "ory_ac_"
	prefixAccess  = "ory_at_"
	prefixRefresh = "ory_rt_"
	tokenKeyBytes = 32
)

var b64 = base64.RawURLEncoding

// hmacTokens makes and checks tokens under one 32-byte secret.
type hmacTokens struct {
	secret [32]byte
}

func newHMACTokens(secret []byte) hmacTokens {
	var t hmacTokens
	copy(t.secret[:], secret)
	return t
}

func (t hmacTokens) mac(key []byte) []byte {
	h := hmac.New(sha512.New512_256, t.secret[:])
	_, _ = h.Write(key) // never fails
	return h.Sum(nil)
}

// generate returns a new token of the given kind and the signature it is stored under.
func (t hmacTokens) generate(prefix string) (token, signature string) {
	key := make([]byte, tokenKeyBytes)
	_, _ = rand.Read(key) // never fails (crypto/rand)
	signature = b64.EncodeToString(t.mac(key))
	return prefix + b64.EncodeToString(key) + "." + signature, signature
}

// signature checks that token is one of this relay's tokens of the given kind and returns the
// signature it is stored under. Anything else (another kind, a forged or altered token, any
// other string) is not a token: false, without a database lookup.
func (t hmacTokens) signature(prefix, token string) (string, bool) {
	rest, ok := strings.CutPrefix(token, prefix)
	if !ok {
		return "", false
	}
	key64, sig64, ok := strings.Cut(rest, ".")
	if !ok || key64 == "" || sig64 == "" {
		return "", false
	}
	key, err := b64.DecodeString(key64)
	if err != nil {
		return "", false
	}
	sig, err := b64.DecodeString(sig64)
	if err != nil || !hmac.Equal(sig, t.mac(key)) {
		return "", false
	}
	return sig64, true
}
