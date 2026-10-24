package agentproto_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
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
	obj := map[string]any{"type": "object"}
	ok := []*mcp.Tool{{Name: "battery_status", InputSchema: obj}, {Name: "other.v2", InputSchema: obj, OutputSchema: obj}}
	require.NoError(t, agentproto.ValidateTools(ok))
	require.NoError(t, agentproto.ValidateTools(nil))
	require.ErrorIs(t, agentproto.ValidateTools([]*mcp.Tool{{Name: agentproto.RelayToolLaptopStatus, InputSchema: obj}}), agentproto.ErrProtocolViolation)
	require.ErrorIs(t, agentproto.ValidateTools([]*mcp.Tool{nil}), agentproto.ErrProtocolViolation)
}

// A tool the MCP SDK's AddTool would panic on must be a protocol violation on arrival, never
// reach the SDK (security scan: x-mcp-header annotations).
func TestValidateToolsRejectsWhatTheSDKRefuses(t *testing.T) {
	schema := func(props string) map[string]any {
		var m map[string]any
		require.NoError(t, json.Unmarshal([]byte(`{"type":"object","properties":`+props+`}`), &m))
		return m
	}
	bad := map[string]string{
		"header on an object":         `{"p":{"type":"object","x-mcp-header":"X-A"}}`,
		"header on an array":          `{"p":{"type":"array","x-mcp-header":"X-A"}}`,
		"header value not a string":   `{"p":{"type":"string","x-mcp-header":7}}`,
		"empty header":                `{"p":{"type":"string","x-mcp-header":""}}`,
		"header with a space":         `{"p":{"type":"string","x-mcp-header":"X A"}}`,
		"header with a newline":       `{"p":{"type":"string","x-mcp-header":"X\nA"}}`,
		"duplicate, case-insensitive": `{"a":{"type":"string","x-mcp-header":"X-A"},"b":{"type":"object","properties":{"c":{"type":"integer","x-mcp-header":"x-a"}}}}`,
		"nested header on an object":  `{"a":{"type":"object","properties":{"b":{"type":"object","x-mcp-header":"X-B"}}}}`,
	}
	for name, props := range bad {
		tool := &mcp.Tool{Name: "t", InputSchema: schema(props)}
		require.ErrorIs(t, agentproto.ValidateTools([]*mcp.Tool{tool}), agentproto.ErrProtocolViolation, name)
	}
	good := []*mcp.Tool{
		{Name: "a", InputSchema: schema(`{"p":{"type":"string","x-mcp-header":"X-A"},"q":{"type":"boolean","x-mcp-header":"X-B"}}`)},
		{Name: "b", InputSchema: schema(`{"p":{"type":"object","properties":{"n":{"type":"integer","x-mcp-header":"X-A"}}}}`)},
	}
	require.NoError(t, agentproto.ValidateTools(good))
	srv := mcp.NewServer(&mcp.Implementation{Name: "check", Version: "0"}, nil)
	for _, tool := range good {
		assert.NotPanics(t, func() {
			srv.AddTool(tool, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) { return nil, nil })
		}, "everything ValidateTools accepts, AddTool accepts")
	}
}

type signatureFixture struct {
	PublicKey string `json:"public_key"`
	Nonce     string `json:"nonce"`
	DeviceID  string `json:"device_id"`
	Signature string `json:"signature"`
}

// TestCrossLanguageSignatures: a Go-made signature fixture for the Swift tests (written once),
// and the Swift-made one (written by the Swift tests) must verify here.
func TestCrossLanguageSignatures(t *testing.T) {
	dir := filepath.Join(fixtureDir, "signatures")
	goFile := filepath.Join(dir, "go.json")
	if _, err := os.Stat(goFile); os.IsNotExist(err) {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		require.NoError(t, err)
		der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
		require.NoError(t, err)
		nonce := "q3Jt0b8bK9mH2y1cX7vLZ0aP4sE6dR5fG8hJ1kM2nQo"
		data, err := json.MarshalIndent(signatureFixture{
			PublicKey: base64.RawURLEncoding.EncodeToString(der), Nonce: nonce, DeviceID: "dev_go",
			Signature: sign(t, key, nonce, "dev_go"),
		}, "", "  ")
		require.NoError(t, err)
		require.NoError(t, os.MkdirAll(dir, 0o755))
		require.NoError(t, os.WriteFile(goFile, append(data, '\n'), 0o600))
	}
	for _, name := range []string{"go.json", "swift.json"} {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if os.IsNotExist(err) && name == "swift.json" {
			t.Log("swift.json not written yet; run the Mac app tests")
			continue
		}
		require.NoError(t, err)
		var f signatureFixture
		require.NoError(t, json.Unmarshal(data, &f))
		der, err := base64.RawURLEncoding.DecodeString(f.PublicKey)
		require.NoError(t, err)
		pub, err := x509.ParsePKIXPublicKey(der)
		require.NoError(t, err)
		ec, ok := pub.(*ecdsa.PublicKey)
		require.True(t, ok)
		require.NoError(t, agentproto.VerifySignature(ec, f.Nonce, f.DeviceID, f.Signature), name)
	}
}
