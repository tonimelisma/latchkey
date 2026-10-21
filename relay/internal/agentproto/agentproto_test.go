package agentproto_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
)

const fixtureDir = "../../../specs/001-core/contracts/fixtures"

func fixtures(t *testing.T, kind string) map[string][]byte {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(fixtureDir, kind, "*.json"))
	require.NoError(t, err)
	require.NotEmpty(t, paths, "no fixtures in %s", kind)
	out := make(map[string][]byte, len(paths))
	for _, p := range paths {
		data, err := os.ReadFile(p)
		require.NoError(t, err)
		out[filepath.Base(p)] = data
	}
	return out
}

func TestValidFixturesRoundTrip(t *testing.T) {
	for name, data := range fixtures(t, "valid") {
		t.Run(name, func(t *testing.T) {
			msg, err := agentproto.Decode(data)
			require.NoError(t, err)
			encoded, err := agentproto.Encode(msg)
			require.NoError(t, err)
			assert.JSONEq(t, string(data), string(encoded))
		})
	}
}

func TestEveryMessageTypeHasAValidFixture(t *testing.T) {
	seen := map[agentproto.Type]bool{}
	for _, data := range fixtures(t, "valid") {
		msg, err := agentproto.Decode(data)
		require.NoError(t, err)
		seen[msg.MessageType()] = true
	}
	for _, typ := range agentproto.AllTypes {
		assert.True(t, seen[typ], "no valid fixture for %q", typ)
	}
}

func TestToleratedFixturesDecode(t *testing.T) {
	for name, data := range fixtures(t, "tolerated") {
		t.Run(name, func(t *testing.T) {
			_, err := agentproto.Decode(data)
			require.NoError(t, err)
		})
	}
}

func TestInvalidFixturesAreProtocolViolations(t *testing.T) {
	for name, data := range fixtures(t, "invalid") {
		t.Run(name, func(t *testing.T) {
			_, err := agentproto.Decode(data)
			require.ErrorIs(t, err, agentproto.ErrProtocolViolation)
		})
	}
}

func TestDecodeGivesTypedMessages(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(fixtureDir, "valid", "hello.json"))
	require.NoError(t, err)
	msg, err := agentproto.Decode(data)
	require.NoError(t, err)
	hello, ok := msg.(*agentproto.Hello)
	require.True(t, ok, "got %T", msg)
	assert.Equal(t, "dev_8f3kq2m7xz", hello.DeviceID)
	assert.Equal(t, 82, hello.State.BatteryPercent)
	require.NotNil(t, hello.State.LidClosed)
	assert.True(t, *hello.State.LidClosed)
	require.NotNil(t, hello.State.TimeZone)
	assert.Equal(t, "America/Los_Angeles", *hello.State.TimeZone)
	assert.Equal(t, time.Date(2026, 10, 19, 17, 2, 10, 0, time.UTC), hello.State.ObservedAt)
	require.Len(t, hello.Tools, 1)
	assert.Equal(t, "battery_status", hello.Tools[0].Name)
}

func TestToolDeadline(t *testing.T) {
	tests := []struct {
		name string
		meta mcp.Meta
		want time.Duration
	}{
		{"no meta", nil, 10 * time.Second},
		{"declared", mcp.Meta{agentproto.DeadlineMetaKey: float64(5000)}, 5 * time.Second},
		{"capped", mcp.Meta{agentproto.DeadlineMetaKey: float64(120000)}, 60 * time.Second},
		{"zero", mcp.Meta{agentproto.DeadlineMetaKey: float64(0)}, 10 * time.Second},
		{"negative", mcp.Meta{agentproto.DeadlineMetaKey: float64(-5)}, 10 * time.Second},
		{"not a number", mcp.Meta{agentproto.DeadlineMetaKey: "5000"}, 10 * time.Second},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tool := &mcp.Tool{Name: "x", Meta: tt.meta}
			assert.Equal(t, tt.want, agentproto.ToolDeadline(tool))
		})
	}
}

func TestSignatureInput(t *testing.T) {
	got := agentproto.SignatureInput("abc", "dev_1")
	assert.Equal(t, []byte("latchkey-agent-v1\nabc\ndev_1"), got)
}

func sign(t *testing.T, key *ecdsa.PrivateKey, nonce, deviceID string) string {
	t.Helper()
	digest := sha256.Sum256(agentproto.SignatureInput(nonce, deviceID))
	der, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	require.NoError(t, err)
	return base64.RawURLEncoding.EncodeToString(der)
}

func TestVerifySignature(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	other, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	nonce, err := agentproto.NewNonce()
	require.NoError(t, err)
	sig := sign(t, key, nonce, "dev_1")

	require.NoError(t, agentproto.VerifySignature(&key.PublicKey, nonce, "dev_1", sig))

	cases := map[string]struct {
		pub      *ecdsa.PublicKey
		nonce    string
		deviceID string
		sig      string
	}{
		"wrong key":      {&other.PublicKey, nonce, "dev_1", sig},
		"other nonce":    {&key.PublicKey, nonce + "x", "dev_1", sig},
		"other device":   {&key.PublicKey, nonce, "dev_2", sig},
		"padded base64":  {&key.PublicKey, nonce, "dev_1", sig + "="},
		"not base64":     {&key.PublicKey, nonce, "dev_1", "!!!"},
		"empty":          {&key.PublicKey, nonce, "dev_1", ""},
		"truncated":      {&key.PublicKey, nonce, "dev_1", sig[:len(sig)/2]},
		"std base64 alt": {&key.PublicKey, nonce, "dev_1", base64.StdEncoding.EncodeToString([]byte("garbage"))},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			require.ErrorIs(t, agentproto.VerifySignature(c.pub, c.nonce, c.deviceID, c.sig), agentproto.ErrBadSignature)
		})
	}
}

func TestNewNonceIs32RandomBytes(t *testing.T) {
	a, err := agentproto.NewNonce()
	require.NoError(t, err)
	b, err := agentproto.NewNonce()
	require.NoError(t, err)
	assert.NotEqual(t, a, b)
	raw, err := base64.RawURLEncoding.DecodeString(a)
	require.NoError(t, err)
	assert.Len(t, raw, 32)
}

func TestValidateTools(t *testing.T) {
	ok := []*mcp.Tool{{Name: "battery_status"}, {Name: "other"}}
	require.NoError(t, agentproto.ValidateTools(ok))
	require.NoError(t, agentproto.ValidateTools(nil))
	require.ErrorIs(t, agentproto.ValidateTools([]*mcp.Tool{{Name: agentproto.RelayToolLaptopStatus}}), agentproto.ErrProtocolViolation)
	require.ErrorIs(t, agentproto.ValidateTools([]*mcp.Tool{nil}), agentproto.ErrProtocolViolation)
}
