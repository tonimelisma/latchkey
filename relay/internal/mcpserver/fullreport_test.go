package mcpserver_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/agentproto"
	"github.com/tonimelisma/latchkey/relay/internal/mcpserver"
	"github.com/tonimelisma/latchkey/relay/internal/reportlog"
	"github.com/tonimelisma/latchkey/relay/internal/trace"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// fullEnv is a relay with traces, the relay's log ring, and a stand-in intake that refuses
// bodies over maxBody with 413, as an intake from before 5 MB reports does (0: no limit).
func fullEnv(t *testing.T, partDeadline time.Duration, maxBody int) (*env, *fakeIntake, *reportlog.Ring, string) {
	t.Helper()
	pub, priv, err := reports.GenerateKey()
	require.NoError(t, err)
	pk, err := reports.PublicKey(pub)
	require.NoError(t, err)
	ts, err := trace.New(trace.Options{
		Dir: filepath.Join(t.TempDir(), "traces"), Key: bytes.Repeat([]byte{5}, 32),
		FreeSpace: func(string) (uint64, error) { return 100 << 30, nil },
	})
	require.NoError(t, err)
	intake := &fakeIntake{}
	var handler http.Handler = intake
	if maxBody > 0 {
		handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			if len(body) > maxBody {
				http.Error(w, "too large", http.StatusRequestEntityTooLarge)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			intake.ServeHTTP(w, r)
		})
	}
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	ring := reportlog.New(nil)
	e := setupWith(t, mcpserver.Options{
		Traces: ts, RelayLog: ring, PartDeadline: partDeadline,
		Logger:  slog.New(ring.Wrap(slog.DiscardHandler)),
		Reports: mcpserver.ReportsOptions{IntakeURL: srv.URL, DeveloperKey: pk, Client: srv.Client(), WorkBits: 4},
	})
	return e, intake, ring, priv
}

func objectTool(name string) *mcp.Tool {
	return &mcp.Tool{Name: name, Description: name, InputSchema: map[string]any{"type": "object"}}
}

// partAnswer is what the stand-in Mac gives as its part.
const partAnswer = `{"log":[{"time":"2026-11-25T03:12:00Z","category":"browser","text":"page pk4m2 took 2 cookies from Safari"}],` +
	`"pages":[{"name":"pk4m2","where":"own","address":"https://shop.example/cart","source":"<html><body>Cart</body></html>",` +
	`"cookies":["session"],"drawing":{"visibility":"hidden","mac_locked":true},` +
	`"record":[{"kind":"request","address":"https://shop.example/api/checkout","status":403}]}]}`

// sharingMac pairs the stand-in Mac with browser and sign-in tools, answering the relay's
// request for its part with part (after wait).
func sharingMac(t *testing.T, e *env, wait time.Duration, part string) {
	t.Helper()
	e.pair()
	share := true
	e.agent.State.ShareReports = &share
	e.agent.Features = []string{agentproto.FeatureReportPart}
	e.agent.Tools = append(e.agent.Tools, objectTool("browser_look"), objectTool("logins_fill"))
	e.agent.Handler = func(ctx context.Context, call *agentproto.Call) *agentproto.Result {
		text := "ok"
		switch call.Tool {
		case agentproto.ReportPartTool:
			var a agentproto.ReportPartArgs
			require.NoError(t, json.Unmarshal(call.Arguments, &a))
			assert.Contains(t, a.Pages, "pk4m2", "the chat's pages are asked for")
			assert.Len(t, a.CallIDs, 2, "the chat's calls")
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return nil
			}
			text = part
		case "browser_look":
			text = "Opened page pk4m2: Cart on Toni's MacBook Pro (owner@example.com)"
		case "logins_fill":
			text = "Typed the code 482913 into e7 and pressed e9"
		}
		content, _ := json.Marshal([]map[string]any{{"type": "text", "text": text}})
		return &agentproto.Result{ID: call.ID, Content: content}
	}
	e.connectMac()
}

// openOne opens the one report the intake got.
func openOne(t *testing.T, intake *fakeIntake, priv string) map[string]any {
	t.Helper()
	require.Eventually(t, func() bool { return len(intake.received()) == 1 }, 15*time.Second, 20*time.Millisecond)
	k, err := reports.PrivateKey(priv)
	require.NoError(t, err)
	plain, err := reports.OpenRaw(k, intake.received()[0])
	require.NoError(t, err)
	var r map[string]any
	require.NoError(t, json.Unmarshal(plain, &r))
	return r
}

// Spec 014 FR-1440 to FR-1449, SC-1405, end to end with a real MCP client: the report carries
// every call of the chat that filed it (not another chat's), the relay's log, and the Mac's part
// with its page; the code Claude passed is nowhere; machine names, the email: labels.
func TestReportCarriesEverythingForThatChat(t *testing.T) {
	e, intake, ring, priv := fullEnv(t, 5*time.Second, 0)
	go e.ms.SendReports(ctx(t))
	sharingMac(t, e, 0, partAnswer)
	chatA := e.client(stateful, nil)
	chatB := e.client(stateful, nil)
	call := func(cs *mcp.ClientSession, name string, args map[string]any) {
		res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: name, Arguments: args})
		require.NoError(t, err)
		require.False(t, res.IsError)
	}
	call(chatA, "browser_look", map[string]any{"url": "https://shop.example/cart"})
	call(chatB, "battery_status", map[string]any{}) // another chat
	call(chatA, "logins_fill", map[string]any{"page": "pk4m2", "field": "e7", "fill": "code", "code": "482913", "press": "e9"})
	slog.New(ring.Wrap(slog.DiscardHandler)).Warn("checkout stalled", "user", e.user.ID)

	res, err := chatA.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{
		"summary": "Checkout did nothing", "details": "clicked Check out, the page stayed",
	}})
	require.NoError(t, err)
	require.False(t, res.IsError, text(t, res))

	r := openOne(t, intake, priv)
	all, _ := json.Marshal(r)
	assert.EqualValues(t, 3, r["format"])
	calls := r["calls"].([]any)
	require.Len(t, calls, 2, "FR-1441: the chat's two calls, not the other chat's: %s", all)
	first := calls[0].(map[string]any)
	assert.Equal(t, "browser_look", first["tool"])
	assert.Equal(t, "machine 1", first["machine"], "FR-1449: the label, never the name")
	assert.Contains(t, string(all), "Opened page pk4m2: Cart", "FR-1440: the whole answer")
	assert.NotContains(t, string(all), "482913", "FR-1448: the code is blanked everywhere")
	assert.Contains(t, string(all), "(blanked)")
	assert.NotContains(t, strings.ToLower(string(all)), "macbook", "FR-1449: no machine name")
	assert.NotContains(t, string(all), e.user.Email, "FR-1449: no email address")
	assert.Contains(t, string(all), "checkout stalled", "FR-1442: the relay's log")
	parts := r["parts"].([]any)
	require.Len(t, parts, 1)
	p := parts[0].(map[string]any)
	assert.Equal(t, true, p["answered"], "%v", p)
	assert.Contains(t, string(all), "api/checkout", "FR-1447: the page's record")
	machines := r["machines"].([]any)
	assert.Equal(t, "machine 1", machines[0].(map[string]any)["label"])
	assert.Equal(t, true, machines[0].(map[string]any)["named"], "it answered the chat's calls: involved")
}

// FR-1443, Constitution II: a machine that doesn't give its part in time is listed as such and
// the report still goes.
func TestReportGoesWithoutALateMachinesPart(t *testing.T) {
	e, intake, _, priv := fullEnv(t, 300*time.Millisecond, 0)
	go e.ms.SendReports(ctx(t))
	sharingMac(t, e, 10*time.Second, partAnswer)
	cs := e.client(stateful, nil)
	for _, c := range []struct {
		name string
		args map[string]any
	}{{"browser_look", map[string]any{}}, {"logins_fill", map[string]any{"page": "pk4m2"}}} {
		_, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: c.name, Arguments: c.args})
		require.NoError(t, err)
	}
	start := time.Now()
	res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{"summary": "x", "details": "y"}})
	require.NoError(t, err)
	require.False(t, res.IsError, text(t, res))
	assert.Less(t, time.Since(start), 5*time.Second, "the answer waits only the part's deadline")
	r := openOne(t, intake, priv)
	p := r["parts"].([]any)[0].(map[string]any)
	assert.Equal(t, false, p["answered"])
	assert.Contains(t, p["note"], "didn't answer within")
}

// FR-1451: an intake that takes only 64 KB gets the report's small version, which says what it
// left out.
func TestOldIntakeGetsTheSmallVersion(t *testing.T) {
	e, intake, _, priv := fullEnv(t, 5*time.Second, reports.OldMaxSealed)
	go e.ms.SendReports(ctx(t))
	big := strings.Replace(partAnswer, "Cart</body>", strings.Repeat("Cart ", 30_000)+"</body>", 1)
	sharingMac(t, e, 0, big)
	cs := e.client(stateful, nil)
	for _, c := range []struct {
		name string
		args map[string]any
	}{{"browser_look", map[string]any{}}, {"logins_fill", map[string]any{"page": "pk4m2"}}} {
		_, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: c.name, Arguments: c.args})
		require.NoError(t, err)
	}
	_, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{"summary": "big", "details": "y"}})
	require.NoError(t, err)
	r := openOne(t, intake, priv)
	assert.Equal(t, "big", r["summary"])
	assert.Nil(t, r["calls"])
	assert.Contains(t, strings.Join(func() []string {
		var out []string
		for _, v := range r["left_out"].([]any) {
			out = append(out, v.(string))
		}
		return out
	}(), " "), "only small reports")
}

// namedClient is a client of the given protocol version that calls itself name (the Claude app).
func (e *env) namedClient(version, name string) *mcp.ClientSession {
	e.t.Helper()
	c := mcp.NewClient(&mcp.Implementation{Name: name, Version: "1"}, nil)
	cs, err := c.Connect(ctx(e.t), &mcp.StreamableClientTransport{
		Endpoint:   e.srv.URL + "/mcp",
		HTTPClient: &http.Client{Transport: bearer{"token-" + e.user.ID}},
		MaxRetries: -1,
	}, &mcp.ClientSessionOptions{ProtocolVersion: version})
	require.NoError(e.t, err)
	e.t.Cleanup(func() { _ = cs.Close() })
	return cs
}

// Problem reports of 2026-11-26/27: claude.ai and Claude Code both use the protocol without
// sessions, and every report came with no calls, no pages and under a minute of log. FR-1441: a
// client without sessions gets its calls from the same Claude app in the last 2 hours (not
// another app's); the Mac is asked for those calls and their pages; the relay's own starts and
// stops are in the relay's log (FR-1442a).
func TestReportWithoutASessionCarriesTheAppsCalls(t *testing.T) {
	e, intake, ring, priv := fullEnv(t, 5*time.Second, 0)
	go e.ms.SendReports(ctx(t))
	sharingMac(t, e, 0, partAnswer)
	app := e.namedClient(stateless, "Anthropic/ClaudeAI")
	other := e.namedClient(stateless, "another-app")
	call := func(cs *mcp.ClientSession, name string, args map[string]any) {
		res, err := cs.CallTool(ctx(t), &mcp.CallToolParams{Name: name, Arguments: args})
		require.NoError(t, err)
		require.False(t, res.IsError)
	}
	call(app, "browser_look", map[string]any{"url": "https://shop.example/cart"})
	call(other, "battery_status", map[string]any{})
	call(app, "logins_fill", map[string]any{"page": "pk4m2", "field": "e7", "fill": "code", "code": "482913", "press": "e9"})
	slog.New(ring.Wrap(slog.DiscardHandler)).Info("shutting down", reportlog.RelayWide, true)

	res, err := app.CallTool(ctx(t), &mcp.CallToolParams{Name: "feedback", Arguments: map[string]any{
		"summary": "The page came up signed out", "details": "opened the dashboard, saw the sign-in form",
	}})
	require.NoError(t, err)
	require.False(t, res.IsError, text(t, res))

	r := openOne(t, intake, priv)
	all, _ := json.Marshal(r)
	calls, _ := r["calls"].([]any)
	require.Len(t, calls, 2, "the app's two calls, not the other app's: %s", all)
	assert.Equal(t, "browser_look", calls[0].(map[string]any)["tool"])
	assert.NotContains(t, string(all), "battery_status", "another Claude app's call")
	assert.NotContains(t, string(all), "482913", "FR-1448: the code is blanked everywhere")
	ch := r["chat"].(map[string]any)
	assert.Contains(t, ch["how"], "Anthropic/ClaudeAI", "says whose calls they are")
	assert.Contains(t, string(all), "shutting down", "FR-1442a: the relay's own starts and stops")
	assert.Contains(t, string(all), "api/checkout", "the Mac was asked for the page the calls used")
}
