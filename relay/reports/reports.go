// Package reports is the format of a problem report a relay forwards to the developer's intake
// (spec 014): the report's fields, its encryption to the developer's public key with the
// standard library's HPKE (RFC 9180), and the small proof of work the intake asks of a sender.
// The relay seals and proves; the intake checks the proof and the shape; only the developer's
// own command opens a report.
package reports

import (
	"bytes"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math/bits"
	"strings"
	"time"
)

// The suite (spec 014 research.md): a post-quantum hybrid KEM, as reports may wait a long time,
// HKDF-SHA256, and ChaCha20-Poly1305.
var (
	kem  = hpke.MLKEM768X25519()
	kdf  = hpke.HKDFSHA256()
	aead = hpke.ChaCha20Poly1305()
)

// Info binds a sealed report to this format's version.
const Info = "latchkey-report-v1"

// Magic starts every sealed report, so the intake can refuse anything else at once.
const Magic = "LKR1"

// MaxSealed is the largest sealed report the intake takes (FR-1420).
const MaxSealed = 64 << 10

// WorkBits is how many leading zero bits the proof of work needs: about a second of one CPU
// (research.md).
const WorkBits = 20

// Report is what a sealed report holds (FR-1412, contract feedback-intake.md).
type Report struct {
	Format int `json:"format"`
	// ID is the id the feedback tool gave Claude (fb_…), so the user's chat and the developer's
	// list name the same report (Toni, 2026-11-24).
	ID           string    `json:"id,omitempty"`
	At           time.Time `json:"at"`
	Summary      string    `json:"summary"`
	Details      string    `json:"details"`
	Client       string    `json:"client,omitempty"`
	RelayVersion string    `json:"relay_version,omitempty"`
	// MachineVersion, System and Screen: format 1 only (one machine). Format 2 uses Machines.
	MachineVersion string `json:"machine_version,omitempty"`
	System         string `json:"system,omitempty"`
	Screen         string `json:"screen,omitempty"`
	// Machines (format 2): each machine Claude named as involved, or, when it named none,
	// every machine online at the time (Toni, 2026-11-24). Never a machine's name (FR-1412).
	Machines []Machine `json:"machines,omitempty"`
	Reporter string    `json:"reporter,omitempty"`
}

// Machine is what a report says about one machine (FR-1412).
type Machine struct {
	// Named: Claude named it as involved; false for one listed because Claude named none.
	Named   bool   `json:"named,omitempty"`
	Kind    string `json:"kind,omitempty"` // "mac" or "linux"
	Version string `json:"version,omitempty"`
	System  string `json:"system,omitempty"`
	Screen  string `json:"screen,omitempty"` // "locked" or "unlocked"; Macs only
}

// PublicKey reads a developer public key written as base64 (as GenerateKey gives it).
func PublicKey(b64 string) (hpke.PublicKey, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return nil, fmt.Errorf("the developer key isn't base64: %w", err)
	}
	return kem.NewPublicKey(raw)
}

// PrivateKey reads a developer private key written as base64.
func PrivateKey(b64 string) (hpke.PrivateKey, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return nil, fmt.Errorf("the private key isn't base64: %w", err)
	}
	return kem.NewPrivateKey(raw)
}

// GenerateKey makes a developer key pair, both as base64.
func GenerateKey() (public, private string, err error) {
	k, err := kem.GenerateKey()
	if err != nil {
		return "", "", err
	}
	raw, err := k.Bytes()
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(k.PublicKey().Bytes()), base64.StdEncoding.EncodeToString(raw), nil
}

// Seal encrypts a report to the developer's public key.
func Seal(pk hpke.PublicKey, r Report) ([]byte, error) {
	if r.Format == 0 {
		r.Format = 1
	}
	plain, err := json.Marshal(r)
	if err != nil {
		return nil, err
	}
	return SealRaw(pk, plain)
}

// SealRaw encrypts any JSON entry for the intake to the developer's public key: a problem report,
// or a weekly eval result (spec 015 FR-1530), which carries "kind": "eval". The intake can't
// tell them apart.
func SealRaw(pk hpke.PublicKey, plain []byte) ([]byte, error) {
	ct, err := hpke.Seal(pk, kdf, aead, []byte(Info), plain)
	if err != nil {
		return nil, err
	}
	out := append([]byte(Magic), ct...)
	if len(out) > MaxSealed {
		return nil, errors.New("the report is too long to send")
	}
	return out, nil
}

// Open decrypts a sealed report with the developer's private key.
func Open(k hpke.PrivateKey, sealed []byte) (Report, error) {
	var r Report
	plain, err := OpenRaw(k, sealed)
	if err != nil {
		return r, err
	}
	err = json.Unmarshal(plain, &r)
	return r, err
}

// OpenRaw decrypts a sealed entry and returns its JSON.
func OpenRaw(k hpke.PrivateKey, sealed []byte) ([]byte, error) {
	if !bytes.HasPrefix(sealed, []byte(Magic)) {
		return nil, errors.New("not a sealed Latchkey report")
	}
	plain, err := hpke.Open(k, kdf, aead, []byte(Info), sealed[len(Magic):])
	if err != nil {
		return nil, fmt.Errorf("the report doesn't open with this key: %w", err)
	}
	return plain, nil
}

// Kind is an opened entry's kind: "eval" for a weekly result, "" for a problem report.
func Kind(plain []byte) string {
	var k struct {
		Kind string `json:"kind"`
	}
	_ = json.Unmarshal(plain, &k)
	return k.Kind
}

// minSealed is the shortest a sealed report can be: the magic, the KEM's encapsulation, and the
// AEAD's tag.
var minSealed = len(Magic) + 1120 + 16

// Shaped says whether bytes have the shape of a sealed report (the intake can't open them).
func Shaped(sealed []byte) bool {
	return len(sealed) >= minSealed && len(sealed) <= MaxSealed && bytes.HasPrefix(sealed, []byte(Magic))
}

// Hour is the proof of work's hour: the UTC hour, as text.
func Hour(t time.Time) string { return t.UTC().Truncate(time.Hour).Format("2006-01-02T15Z") }

func workHash(sealed []byte, hour string, nonce uint64) [32]byte {
	body := sha256.Sum256(sealed)
	var n [8]byte
	binary.BigEndian.PutUint64(n[:], nonce)
	h := sha256.New()
	h.Write(body[:])
	h.Write([]byte(hour))
	h.Write(n[:])
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}

func zeroBits(h [32]byte) int {
	n := 0
	for i := 0; i < len(h); i += 8 {
		w := binary.BigEndian.Uint64(h[i : i+8])
		if w != 0 {
			return n + bits.LeadingZeros64(w)
		}
		n += 64
	}
	return n
}

// Prove finds a nonce for the sealed report and the hour (a second of CPU, give or take).
func Prove(sealed []byte, hour string, bitsNeeded int) uint64 {
	for nonce := uint64(0); ; nonce++ {
		if zeroBits(workHash(sealed, hour, nonce)) >= bitsNeeded {
			return nonce
		}
	}
}

// Proven checks a proof of work.
func Proven(sealed []byte, hour string, nonce uint64, bitsNeeded int) bool {
	return zeroBits(workHash(sealed, hour, nonce)) >= bitsNeeded
}
