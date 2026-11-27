package e2e

import (
	"testing"
	"time"

	"github.com/chromedp/cdproto/webauthn"
)

// Regression (the sandbox's first run, 2026-11-26): Chrome 158 refused stored passkeys with "CMTG
// is not supported by this authenticator", because cdproto always sends
// generateCmtgKeyOnNextOperation. A false one is left out; the rest of the credential stays.
func TestCredentialToAddLeavesOutAFalseCMTGField(t *testing.T) {
	c := &webauthn.Credential{CredentialID: []byte{1, 2, 3}, RpID: "relay.latchkey.test", IsResidentCredential: true, SignCount: 4}
	m, err := credentialToAdd(c)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m["generateCmtgKeyOnNextOperation"]; ok {
		t.Fatalf("a false CMTG field is sent: %v", m)
	}
	if m["rpId"] != "relay.latchkey.test" || m["credentialId"] != "AQID" || m["isResidentCredential"] != true || m["signCount"] != float64(4) {
		t.Fatalf("the credential changed: %v", m)
	}
	c.GenerateCmtgKeyOnNextOperation = true
	if m, _ = credentialToAdd(c); m["generateCmtgKeyOnNextOperation"] != true {
		t.Fatalf("a true CMTG field is kept: %v", m)
	}
}

// Regression (the sandbox's first runs, 2026-11-26): the image's stored passkey has the counter
// it had when stored; a second copy's sign-in sent a counter the relay had already seen and was
// refused as a clone. Each run's counter is at least the time in seconds, so it always grows.
func TestStoredPasskeysCountOnFromTheTime(t *testing.T) {
	early := time.Unix(1_800_000_000, 0)
	later := early.Add(time.Minute)
	a := withGrowingCount(&webauthn.Credential{SignCount: 1}, early).SignCount
	b := withGrowingCount(&webauthn.Credential{SignCount: 1}, later).SignCount
	if a < float64(early.Unix()) || b <= a {
		t.Fatalf("counters %.0f then %.0f: each run's must be above the last", a, b)
	}
	if got := withGrowingCount(&webauthn.Credential{SignCount: 5_000_000_000}, later).SignCount; got != 5_000_000_000 {
		t.Fatalf("a higher stored counter is kept: %.0f", got)
	}
}

func TestCredentialToAddKeepsATrueCMTGField(t *testing.T) {
	c := &webauthn.Credential{CredentialID: []byte{1}, GenerateCmtgKeyOnNextOperation: true}
	if m, _ := credentialToAdd(c); m["generateCmtgKeyOnNextOperation"] != true {
		t.Fatalf("a true CMTG field is kept: %v", m)
	}
}
