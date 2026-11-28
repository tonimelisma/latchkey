package keyvault

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestAuthKind(t *testing.T) {
	for name, tc := range map[string]struct {
		env  map[string]string
		want string
	}{
		"cloud session":                  {map[string]string{"MELISMA_SECRETS_CLIENT_SECRET": "s"}, authCloudSession},
		"client secret wins over gce":    {map[string]string{"MELISMA_SECRETS_CLIENT_SECRET": "s", "LATCHKEY_KEYVAULT_AUTH": "gce"}, authCloudSession},
		"google vm":                      {map[string]string{"LATCHKEY_KEYVAULT_AUTH": "gce"}, authGCE},
		"other auth value: the az login": {map[string]string{"LATCHKEY_KEYVAULT_AUTH": "x"}, authCLI},
		"nothing: the az login":          {nil, authCLI},
	} {
		t.Run(name, func(t *testing.T) {
			if got := authKind(env(tc.env)); got != tc.want {
				t.Fatalf("authKind = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestCredentialTypes(t *testing.T) {
	for name, tc := range map[string]struct {
		env   map[string]string
		check func(any) bool
	}{
		"cloud session": {map[string]string{"MELISMA_SECRETS_CLIENT_SECRET": "s"}, func(c any) bool { _, ok := c.(*azidentity.ClientSecretCredential); return ok }},
		"google vm":     {map[string]string{"LATCHKEY_KEYVAULT_AUTH": "gce"}, func(c any) bool { _, ok := c.(*azidentity.ClientAssertionCredential); return ok }},
		"mac":           {nil, func(c any) bool { _, ok := c.(*azidentity.AzureCLICredential); return ok }},
	} {
		t.Run(name, func(t *testing.T) {
			c, err := credential(env(tc.env))
			if err != nil || !tc.check(c) {
				t.Fatalf("credential = %T, %v", c, err)
			}
		})
	}
}

// metadata stands in for a Google VM's metadata server.
func metadata(t *testing.T, status int, body string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Metadata-Flavor") != "Google" || r.URL.Query().Get("audience") != "api://AzureADTokenExchange" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	old := metadataIdentityURL
	metadataIdentityURL = srv.URL + "/computeMetadata/v1/instance/service-accounts/default/identity?audience=api://AzureADTokenExchange&format=full"
	t.Cleanup(func() { metadataIdentityURL = old })
}

func TestGoogleIDToken(t *testing.T) {
	metadata(t, http.StatusOK, "header.payload.signature\n")
	got, err := googleIDToken(context.Background())
	if err != nil || got != "header.payload.signature" {
		t.Fatalf("googleIDToken = %q, %v", got, err)
	}
}

func TestGoogleIDTokenRefused(t *testing.T) {
	metadata(t, http.StatusForbidden, "no")
	if _, err := googleIDToken(context.Background()); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("err = %v, want the metadata server's 403", err)
	}
	metadata(t, http.StatusOK, " ")
	if _, err := googleIDToken(context.Background()); err == nil {
		t.Fatal("an empty token was accepted")
	}
}

// The VM's credential asks the metadata server before it goes anywhere else.
func TestGCECredentialUsesTheMetadataServer(t *testing.T) {
	metadata(t, http.StatusServiceUnavailable, "down")
	c, err := credential(env(map[string]string{"LATCHKEY_KEYVAULT_AUTH": "gce"}))
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.GetToken(context.Background(), policy.TokenRequestOptions{Scopes: []string{"https://vault.azure.net/.default"}})
	if err == nil || !strings.Contains(err.Error(), "metadata server answered 503") {
		t.Fatalf("err = %v, want the metadata server's 503", err)
	}
}

func TestGetPrefersTheEnvironment(t *testing.T) {
	t.Setenv("LATCHKEY_TEST_SECRET", "from-env")
	t.Setenv("LATCHKEY_KEYVAULT_AUTH", "gce")
	metadata(t, http.StatusInternalServerError, "must not be asked")
	got, err := Get(context.Background(), "LATCHKEY_TEST_SECRET", "kv-test", "never-read")
	if err != nil || got != "from-env" {
		t.Fatalf("Get = %q, %v", got, err)
	}
}

func TestGetErrorNamesWhatAndHow(t *testing.T) {
	t.Setenv("LATCHKEY_TEST_SECRET", "")
	t.Setenv("MELISMA_SECRETS_CLIENT_SECRET", "")
	t.Setenv("LATCHKEY_KEYVAULT_AUTH", "gce")
	metadata(t, http.StatusForbidden, "no")
	mu.Lock()
	cred = nil
	mu.Unlock()
	t.Cleanup(func() { mu.Lock(); cred = nil; mu.Unlock() })
	// No Azure: the vault is a closed local port.
	old := vaultURL
	vaultURL = func(string) string { return "https://127.0.0.1:1" }
	t.Cleanup(func() { vaultURL = old })
	ctx, cancel := context.WithTimeout(context.Background(), time.Second) // not the retries' 9 s
	defer cancel()
	_, err := Get(ctx, "LATCHKEY_TEST_SECRET", "kv-test", "the-secret")
	if err == nil {
		t.Fatal("Get succeeded with no vault")
	}
	for _, want := range []string{"LATCHKEY_TEST_SECRET isn't set", "kv-test/the-secret", authGCE} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q doesn't say %q", err, want)
		}
	}
}

func TestReportsKey(t *testing.T) {
	var asked []string
	var vaultErr error
	get := func(_ context.Context, env, vault, secret string) (string, error) {
		asked = append(asked, env+" "+vault+"/"+secret)
		if vaultErr != nil {
			return "", vaultErr
		}
		return " from-vault\n", nil
	}
	f := filepath.Join(t.TempDir(), "named.key")
	if err := os.WriteFile(f, []byte("from-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct{ key, file, want string }{
		"variable wins":             {"from-env", f, "from-env"},
		"the named file":            {"", f, "from-file"},
		"neither: the vault":        {"", "", "from-vault"},
		"blank variable: the vault": {"  ", "", "from-vault"},
	} {
		t.Run(name, func(t *testing.T) {
			asked = nil
			t.Setenv("LATCHKEY_REPORTS_KEY", tc.key)
			t.Setenv("LATCHKEY_REPORTS_KEY_FILE", tc.file)
			got, err := ReportsKey(context.Background(), get)
			if err != nil || got != tc.want {
				t.Fatalf("ReportsKey = %q, %v; want %q", got, err, tc.want)
			}
			if tc.want == "from-vault" && (len(asked) != 1 || asked[0] != "LATCHKEY_REPORTS_KEY kv-melisma-release/latchkey-reports-private-key") {
				t.Fatalf("vault asked %q", asked)
			}
			if tc.want != "from-vault" && len(asked) != 0 {
				t.Fatalf("vault asked %q", asked)
			}
		})
	}
	t.Setenv("LATCHKEY_REPORTS_KEY", "")
	t.Setenv("LATCHKEY_REPORTS_KEY_FILE", filepath.Join(t.TempDir(), "missing.key"))
	if _, err := ReportsKey(context.Background(), get); err == nil || !strings.Contains(err.Error(), "missing.key") {
		t.Fatalf("a named file that is missing: %v", err)
	}
	t.Setenv("LATCHKEY_REPORTS_KEY_FILE", "")
	vaultErr = errors.New("vault unreachable")
	if _, err := ReportsKey(context.Background(), get); !errors.Is(err, vaultErr) {
		t.Fatalf("the vault's error: %v", err)
	}
}
