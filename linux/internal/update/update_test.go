package update_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/update"
)

type fakeGitHub struct {
	srv      *httptest.Server
	releases []map[string]any
	files    map[string][]byte
}

func newGitHub(t *testing.T) *fakeGitHub {
	g := &fakeGitHub{files: map[string][]byte{}}
	g.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/repos/owner/repo/releases" {
			_ = json.NewEncoder(w).Encode(g.releases)
			return
		}
		data, ok := g.files[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(data)
	}))
	t.Cleanup(g.srv.Close)
	return g
}

// release publishes a version whose program is body, signed with priv.
func (g *fakeGitHub) release(tag string, body []byte, priv ed25519.PrivateKey) {
	g.releaseSignedAs(tag, strings.TrimPrefix(tag, update.TagPrefix), body, priv)
}

// releaseSignedAs publishes under tag a program signed as version signedAs.
func (g *fakeGitHub) releaseSignedAs(tag, signedAs string, body []byte, priv ed25519.PrivateKey) {
	name := "latchkey-linux-" + runtime.GOARCH
	g.files["/dl/"+tag+"/"+name] = body
	g.files["/dl/"+tag+"/"+name+".sig"] = []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(priv, update.Signed(runtime.GOARCH, signedAs, body))) + "\n")
	g.releases = append(g.releases, map[string]any{"tag_name": tag, "assets": []map[string]any{
		{"name": name, "browser_download_url": g.srv.URL + "/dl/" + tag + "/" + name},
		{"name": name + ".sig", "browser_download_url": g.srv.URL + "/dl/" + tag + "/" + name + ".sig"},
	}})
}

func setup(t *testing.T, current string) (*update.Updater, *fakeGitHub, ed25519.PrivateKey, string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)
	p := config.PathsFor(t.TempDir(), "", "", "")
	require.NoError(t, os.MkdirAll(p.Program, 0o755))
	program := filepath.Join(p.Program, "latchkey")
	require.NoError(t, os.WriteFile(program, []byte("old program"), 0o755))
	g := newGitHub(t)
	u := &update.Updater{Paths: p, Repo: "owner/repo", Current: current, PubKey: pub, API: g.srv.URL, HTTP: g.srv.Client(), Now: time.Now}
	return u, g, priv, program
}

func TestNewer(t *testing.T) {
	assert.True(t, update.Newer("0.1.10", "0.1.9"))
	assert.True(t, update.Newer("1.0", "0.9.9"))
	assert.False(t, update.Newer("0.1.2", "0.1.2"))
	assert.False(t, update.Newer("0.1.1", "0.1.2"))
}

func TestUpdateInstallsASignedNewerRelease(t *testing.T) {
	u, g, priv, program := setup(t, "0.1.0")
	g.release("server-v0.1.1", []byte("new program"), priv)
	g.release("v9.9.9", []byte("the Mac app, not ours"), priv)
	g.releases = append(g.releases, map[string]any{"tag_name": "server-v0.2.0", "draft": true})

	v, err := u.Update(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "0.1.1", v)
	data, _ := os.ReadFile(program)
	assert.Equal(t, "new program", string(data))
	prev, _ := os.ReadFile(program + ".previous")
	assert.Equal(t, "old program", string(prev), "the previous version is kept")

	// The new version starts and waits for the relay's welcome.
	u.Current = "0.1.1"
	rollBack, awaiting := u.Started()
	assert.False(t, rollBack)
	assert.True(t, awaiting)
	assert.False(t, u.Confirmed())
	u.Confirm()
	assert.True(t, u.Confirmed())
	_, awaiting = u.Started()
	assert.False(t, awaiting, "confirmed: nothing more to wait for")

	_, err = u.Update(context.Background())
	require.ErrorIs(t, err, update.ErrUpToDate)
}

func TestUpdateRefusesABadSignature(t *testing.T) {
	u, g, _, program := setup(t, "0.1.0")
	_, otherKey, _ := ed25519.GenerateKey(rand.Reader)
	g.release("server-v0.1.1", []byte("evil program"), otherKey)
	_, err := u.Update(context.Background())
	require.ErrorContains(t, err, "signature doesn't match")
	data, _ := os.ReadFile(program)
	assert.Equal(t, "old program", string(data), "nothing replaced")
}

// An old signed program relabeled with a newer release's tag is refused: the signature covers the
// version (security review, 2026-10-31).
func TestUpdateRefusesARelabeledOldRelease(t *testing.T) {
	u, g, priv, program := setup(t, "0.1.5")
	g.releaseSignedAs("server-v0.2.0", "0.1.0", []byte("old vulnerable program"), priv)
	_, err := u.Update(context.Background())
	require.ErrorContains(t, err, "isn't Latchkey's signed release 0.2.0")
	data, _ := os.ReadFile(program)
	assert.Equal(t, "old program", string(data))
}

func TestRollBackAfterThreeUnconfirmedStarts(t *testing.T) {
	u, g, priv, program := setup(t, "0.1.0")
	g.release("server-v0.1.1", []byte("broken program"), priv)
	_, err := u.Update(context.Background())
	require.NoError(t, err)
	u.Current = "0.1.1"
	for range 2 {
		rollBack, _ := u.Started()
		require.False(t, rollBack)
	}
	rollBack, _ := u.Started()
	assert.True(t, rollBack, "the third start without a welcome goes back")
	data, _ := os.ReadFile(program)
	assert.Equal(t, "old program", string(data))

	// The rolled-back version is skipped from now on; a newer one is taken.
	u.Current = "0.1.0"
	_, err = u.Update(context.Background())
	require.ErrorIs(t, err, update.ErrUpToDate)
	g.release("server-v0.1.2", []byte("fixed program"), priv)
	v, err := u.Update(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "0.1.2", v)
}

func TestBuiltInKeyIsValid(t *testing.T) {
	assert.Len(t, update.PublicKey(), ed25519.PublicKeySize)
}
