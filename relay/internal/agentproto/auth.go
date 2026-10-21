package agentproto

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const signaturePrefix = "latchkey-agent-v1\n"

// Deadlines (plan D3).
const (
	DefaultDeadline = 10 * time.Second
	MaxDeadline     = 60 * time.Second
	DeadlineMetaKey = "latchkey/deadline_ms"
)

// NewNonce returns 32 random bytes, base64url without padding.
func NewNonce() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// SignatureInput is the byte string the agent signs in hello.
func SignatureInput(nonce, deviceID string) []byte {
	return []byte(signaturePrefix + nonce + "\n" + deviceID)
}

// VerifySignature checks a hello signature: ECDSA P-256, SHA-256, ASN.1 DER, base64url unpadded.
func VerifySignature(pub *ecdsa.PublicKey, nonce, deviceID, signature string) error {
	der, err := base64.RawURLEncoding.DecodeString(signature)
	if err != nil || len(der) == 0 {
		return ErrBadSignature
	}
	digest := sha256.Sum256(SignatureInput(nonce, deviceID))
	if !ecdsa.VerifyASN1(pub, digest[:], der) {
		return ErrBadSignature
	}
	return nil
}

// ToolDeadline is the tool's declared deadline, defaulting to 10 s and capped at 60 s.
func ToolDeadline(t *mcp.Tool) time.Duration {
	ms, ok := t.Meta[DeadlineMetaKey].(float64)
	if !ok || ms <= 0 {
		return DefaultDeadline
	}
	return min(time.Duration(ms)*time.Millisecond, MaxDeadline)
}
