package reports_test

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/reports"
)

// Spec 014 FR-1413, FR-1430: a report sealed to the developer's key opens only with its private
// key, and its sealed bytes hold none of its words.
func TestASealedReportOpensOnlyWithTheDevelopersKey(t *testing.T) {
	pub, priv, err := reports.GenerateKey()
	require.NoError(t, err)
	pk, err := reports.PublicKey(pub)
	require.NoError(t, err)
	r := reports.Report{
		At: time.Date(2026, 11, 23, 5, 45, 16, 0, time.UTC), Summary: "Safari script failed",
		Details: "browser_act script answered theAnswer is not defined", Client: "claude-code", Reporter: "3f9a",
	}
	sealed, err := reports.Seal(pk, r)
	require.NoError(t, err)
	assert.True(t, reports.Shaped(sealed))
	assert.NotContains(t, string(sealed), "Safari", "nothing readable")

	k, err := reports.PrivateKey(priv)
	require.NoError(t, err)
	got, err := reports.Open(k, sealed)
	require.NoError(t, err)
	r.Format = 1
	assert.Equal(t, r, got)

	_, otherPriv, err := reports.GenerateKey()
	require.NoError(t, err)
	other, err := reports.PrivateKey(otherPriv)
	require.NoError(t, err)
	_, err = reports.Open(other, sealed)
	assert.Error(t, err, "another key opens nothing")
}

// FR-1420: the intake takes only report-shaped bytes, within the size limit.
func TestOnlyReportShapedBytesPass(t *testing.T) {
	assert.False(t, reports.Shaped([]byte("LKR1hello")))
	assert.False(t, reports.Shaped([]byte(strings.Repeat("x", 2000))))
	assert.False(t, reports.Shaped(append([]byte(reports.Magic), make([]byte, reports.MaxSealed)...)))
}

// FR-1420: a proof of work is found by the sender and checked cheaply; it is bound to the report
// and the hour.
func TestProofOfWork(t *testing.T) {
	sealed := []byte("LKR1 some sealed bytes")
	hour := reports.Hour(time.Date(2026, 11, 23, 5, 45, 0, 0, time.UTC))
	assert.Equal(t, "2026-11-23T05Z", hour)
	nonce := reports.Prove(sealed, hour, 12)
	assert.True(t, reports.Proven(sealed, hour, nonce, 12))
	assert.False(t, reports.Proven([]byte("LKR1 other bytes"), hour, nonce, 12), "bound to the report")
	assert.False(t, reports.Proven(sealed, "2026-11-23T06Z", nonce, 12), "bound to the hour")
}

// The built-in developer key is a valid public key of this suite.
func TestTheDefaultDeveloperKeyReads(t *testing.T) {
	_, err := reports.PublicKey(reports.DefaultDeveloperKey())
	require.NoError(t, err)
	assert.Contains(t, reports.DefaultIntakeURL, "https://")
}

// The requirements this file's tests cite (docs/requirements/; script/process-check).
// Validates: FR-1413, FR-1420, FR-1430
