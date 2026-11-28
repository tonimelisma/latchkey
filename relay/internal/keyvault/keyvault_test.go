package keyvault

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/cloud"
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

// Stand-in values: no real tenant, app or vault.
const (
	testTenant = "00000000-0000-0000-0000-00000000aaaa"
	testClient = "00000000-0000-0000-0000-00000000bbbb"
	testVault  = "kv-stand-in"
)

func TestCredentialTypes(t *testing.T) {
	for name, tc := range map[string]struct {
		env   map[string]string
		check func(any) bool
	}{
		"cloud session": {
			map[string]string{"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": testClient, "MELISMA_SECRETS_CLIENT_SECRET": "s"},
			func(c any) bool { _, ok := c.(*azidentity.ClientSecretCredential); return ok },
		},
		"google vm": {
			map[string]string{"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": testClient, "LATCHKEY_KEYVAULT_AUTH": "gce"},
			func(c any) bool { _, ok := c.(*azidentity.ClientAssertionCredential); return ok },
		},
		"mac": {
			map[string]string{"AZURE_TENANT_ID": testTenant},
			func(c any) bool { _, ok := c.(*azidentity.AzureCLICredential); return ok },
		},
	} {
		t.Run(name, func(t *testing.T) {
			c, err := credential(env(tc.env))
			if err != nil || !tc.check(c) {
				t.Fatalf("credential = %T, %v", c, err)
			}
		})
	}
}

// There is no built-in tenant or app: a sign-in without its variable says which one is missing,
// and no value.
func TestCredentialNamesTheMissingVariable(t *testing.T) {
	for name, tc := range map[string]struct {
		env     map[string]string
		missing string
	}{
		"cloud session, no tenant": {map[string]string{"AZURE_CLIENT_ID": testClient, "MELISMA_SECRETS_CLIENT_SECRET": "the-secret"}, "AZURE_TENANT_ID"},
		"cloud session, no app":    {map[string]string{"AZURE_TENANT_ID": testTenant, "MELISMA_SECRETS_CLIENT_SECRET": "the-secret"}, "AZURE_CLIENT_ID"},
		"google vm, no tenant":     {map[string]string{"AZURE_CLIENT_ID": testClient, "LATCHKEY_KEYVAULT_AUTH": "gce"}, "AZURE_TENANT_ID"},
		"google vm, no app":        {map[string]string{"AZURE_TENANT_ID": testTenant, "LATCHKEY_KEYVAULT_AUTH": "gce"}, "AZURE_CLIENT_ID"},
		"google vm, blank app":     {map[string]string{"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": " ", "LATCHKEY_KEYVAULT_AUTH": "gce"}, "AZURE_CLIENT_ID"},
		"mac, no tenant":           {map[string]string{"AZURE_CLIENT_ID": testClient}, "AZURE_TENANT_ID"},
	} {
		t.Run(name, func(t *testing.T) {
			c, err := credential(env(tc.env))
			if err == nil {
				t.Fatalf("credential = %T without %s", c, tc.missing)
			}
			if !strings.Contains(err.Error(), tc.missing+" isn't set") {
				t.Fatalf("error %q doesn't name %s", err, tc.missing)
			}
			for _, v := range tc.env {
				if strings.TrimSpace(v) != "" && strings.Contains(err.Error(), v) && v != "gce" {
					t.Fatalf("error %q shows the value %q", err, v)
				}
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

// The VM's credential asks the metadata server for the assertion, and its error is the answer.
func TestGCECredentialUsesTheMetadataServer(t *testing.T) {
	metadata(t, http.StatusServiceUnavailable, "down")
	newAzure(t, testTenant, "unused", "unused") // never the real Entra
	c, err := credential(env(map[string]string{"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": testClient, "LATCHKEY_KEYVAULT_AUTH": "gce"}))
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
	got, err := Get(context.Background(), "LATCHKEY_TEST_SECRET", "LATCHKEY_TEST_VAULT", "never-read") // and no vault named
	if err != nil || got != "from-env" {
		t.Fatalf("Get = %q, %v", got, err)
	}
}

func TestGetErrorNamesWhatAndHow(t *testing.T) {
	onlyEnv(t, map[string]string{
		"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": testClient, "LATCHKEY_KEYVAULT_AUTH": "gce", "LATCHKEY_TEST_VAULT": testVault,
	})
	metadata(t, http.StatusForbidden, "no")
	resetCredential(t)
	// No Azure: the vault is a closed local port.
	old := vaultURL
	vaultURL = func(string) string { return "https://127.0.0.1:1" }
	t.Cleanup(func() { vaultURL = old })
	ctx, cancel := context.WithTimeout(context.Background(), time.Second) // not the retries' 9 s
	defer cancel()
	_, err := Get(ctx, "LATCHKEY_TEST_SECRET", "LATCHKEY_TEST_VAULT", "the-secret")
	if err == nil {
		t.Fatal("Get succeeded with no vault")
	}
	for _, want := range []string{"LATCHKEY_TEST_SECRET isn't set", "secret the-secret in the Key Vault LATCHKEY_TEST_VAULT names", authGCE} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q doesn't say %q", err, want)
		}
	}
	for _, value := range []string{testTenant, testClient, testVault} {
		if strings.Contains(err.Error(), value) {
			t.Errorf("error %q shows the value %q", err, value)
		}
	}
}

// There is no built-in vault: with neither the secret nor the vault's variable set, Get says so
// before it signs in anywhere.
func TestGetNamesTheMissingVault(t *testing.T) {
	onlyEnv(t, map[string]string{"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": testClient, "LATCHKEY_KEYVAULT_AUTH": "gce"})
	metadata(t, http.StatusInternalServerError, "must not be asked")
	resetCredential(t)
	_, err := Get(context.Background(), "LATCHKEY_TEST_SECRET", "LATCHKEY_TEST_VAULT", "the-secret")
	if err == nil || err.Error() != "LATCHKEY_TEST_SECRET isn't set, and neither is LATCHKEY_TEST_VAULT, the Key Vault to read secret the-secret from" {
		t.Fatalf("err = %v", err)
	}
	if cred != nil {
		t.Fatal("signed in without a vault to read")
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
			if tc.want == "from-vault" && (len(asked) != 1 || asked[0] != "LATCHKEY_REPORTS_KEY LATCHKEY_KEYVAULT_RELEASE/latchkey-reports-private-key") {
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

// signInVariables are every variable the package reads to sign in and find a vault.
var signInVariables = []string{
	"AZURE_TENANT_ID", "AZURE_CLIENT_ID", "MELISMA_SECRETS_CLIENT_SECRET", "LATCHKEY_KEYVAULT_AUTH",
	"LATCHKEY_KEYVAULT_HOSTS", "LATCHKEY_KEYVAULT_DEV", "LATCHKEY_KEYVAULT_RELEASE",
	"LATCHKEY_TEST_SECRET", "LATCHKEY_TEST_VAULT",
}

// onlyEnv sets exactly m among signInVariables and clears the rest, so the developer's own
// environment never leaks into a test.
func onlyEnv(t *testing.T, m map[string]string) {
	t.Helper()
	for _, k := range signInVariables {
		t.Setenv(k, m[k])
	}
	for k, v := range m {
		t.Setenv(k, v)
	}
}

// resetCredential forgets the signed-in credential and the values read, now and after the test.
func resetCredential(t *testing.T) {
	t.Helper()
	reset := func() { mu.Lock(); cred = nil; cache = map[string]string{}; mu.Unlock() }
	reset()
	t.Cleanup(reset)
}

// azure stands in for Entra ID and a Key Vault on one local TLS server: Entra answers only for
// tenant and hands out accessToken; the vault answers secret's value to that token after the
// usual challenge. It records each token request's form and the vault the client asked for.
type azure struct {
	tenant, secret, value string
	mu                    sync.Mutex
	tokenForms            []url.Values
	vaults                []string
}

const accessToken = "stand-in-access-token"

func newAzure(t *testing.T, tenant, secret, value string) *azure {
	t.Helper()
	a := &azure{tenant: tenant, secret: secret, value: value}
	srv := httptest.NewTLSServer(a)
	t.Cleanup(srv.Close)
	oldOpts, oldURL := testOptions, vaultURL
	testOptions = &azcore.ClientOptions{
		Transport: srv.Client(),
		Cloud:     cloud.Configuration{ActiveDirectoryAuthorityHost: srv.URL + "/", Services: map[cloud.ServiceName]cloud.ServiceConfiguration{}},
		Retry:     policy.RetryOptions{MaxRetries: -1},
	}
	vaultURL = func(vault string) string {
		a.mu.Lock()
		a.vaults = append(a.vaults, vault)
		a.mu.Unlock()
		return srv.URL
	}
	t.Cleanup(func() { testOptions, vaultURL = oldOpts, oldURL })
	return a
}

func (a *azure) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	base := "https://" + r.Host
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/"+a.tenant+"/v2.0/.well-known/openid-configuration":
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"authorization_endpoint": base + "/" + a.tenant + "/oauth2/v2.0/authorize",
			"token_endpoint":         base + "/" + a.tenant + "/oauth2/v2.0/token",
			"issuer":                 base + "/" + a.tenant + "/v2.0",
		})
	case r.Method == http.MethodPost && r.URL.Path == "/"+a.tenant+"/oauth2/v2.0/token":
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		a.mu.Lock()
		a.tokenForms = append(a.tokenForms, r.PostForm)
		a.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"token_type": "Bearer", "expires_in": 3600, "access_token": accessToken})
	case strings.HasPrefix(r.URL.Path, "/secrets/"+a.secret):
		if r.Header.Get("Authorization") != "Bearer "+accessToken {
			w.Header().Set("WWW-Authenticate", `Bearer authorization="`+base+"/"+a.tenant+`", resource="https://vault.azure.net"`)
			http.Error(w, "sign in", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"value": a.value, "id": base + "/secrets/" + a.secret + "/1"})
	default:
		http.Error(w, "not here: "+r.Method+" "+r.URL.Path, http.StatusNotFound)
	}
}

// fakeAz puts a stand-in for the Azure CLI first on PATH; it answers a token and records its
// arguments in the returned file.
func fakeAz(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	args := filepath.Join(dir, "args")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + args + "'\nprintf '{\"accessToken\":\"" + accessToken + "\",\"expires_on\":4070908800}'\n"
	if err := os.WriteFile(filepath.Join(dir, "az"), []byte(script), 0o700); err != nil { //nolint:gosec // a test's stand-in program
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return args
}

// Each sign-in path, end to end against the stand-ins: the tenant, the app and the vault come
// from exactly the variables each environment sets, and the secret is read.
func TestGetSignsInWithTheEnvironment(t *testing.T) {
	for name, tc := range map[string]struct {
		env      map[string]string
		vaultEnv string
		check    func(t *testing.T, a *azure, azArgs string)
	}{
		// The hosted relay: exactly the names its relay.env sets.
		"google vm (relay.env)": {
			env: map[string]string{
				"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": testClient,
				"LATCHKEY_KEYVAULT_HOSTS": testVault, "LATCHKEY_KEYVAULT_AUTH": "gce",
			},
			vaultEnv: HostsVault,
			check: func(t *testing.T, a *azure, _ string) {
				t.Helper()
				if len(a.tokenForms) != 1 {
					t.Fatalf("token requests %d", len(a.tokenForms))
				}
				f := a.tokenForms[0]
				if f.Get("client_id") != testClient || f.Get("client_assertion") != "the-vm-identity-token" ||
					f.Get("client_assertion_type") != "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" || f.Get("client_secret") != "" {
					t.Fatalf("token request %v", f)
				}
			},
		},
		// A cloud session: the client secret beside the tenant and its app.
		"cloud session": {
			env: map[string]string{
				"AZURE_TENANT_ID": testTenant, "AZURE_CLIENT_ID": testClient,
				"MELISMA_SECRETS_CLIENT_SECRET": "stand-in-client-secret", "LATCHKEY_KEYVAULT_DEV": testVault,
			},
			vaultEnv: DevVault,
			check: func(t *testing.T, a *azure, _ string) {
				t.Helper()
				if len(a.tokenForms) != 1 {
					t.Fatalf("token requests %d", len(a.tokenForms))
				}
				f := a.tokenForms[0]
				if f.Get("client_id") != testClient || f.Get("client_secret") != "stand-in-client-secret" || f.Get("client_assertion") != "" {
					t.Fatalf("token request %v", f)
				}
			},
		},
		// A developer's Mac: az login, in the tenant AZURE_TENANT_ID names; no app.
		"mac (az login)": {
			env:      map[string]string{"AZURE_TENANT_ID": testTenant, "LATCHKEY_KEYVAULT_RELEASE": testVault},
			vaultEnv: ReleaseVault,
			check: func(t *testing.T, a *azure, azArgs string) {
				t.Helper()
				if len(a.tokenForms) != 0 {
					t.Fatalf("Entra asked directly: %v", a.tokenForms)
				}
				b, err := os.ReadFile(azArgs) //nolint:gosec // the test's own file
				if err != nil {
					t.Fatal(err)
				}
				if got := strings.TrimSpace(string(b)); got != "account get-access-token -o json --resource https://vault.azure.net --tenant "+testTenant {
					t.Fatalf("az %s", got)
				}
			},
		},
	} {
		t.Run(name, func(t *testing.T) {
			onlyEnv(t, tc.env)
			resetCredential(t)
			metadata(t, http.StatusOK, "the-vm-identity-token")
			azArgs := fakeAz(t)
			a := newAzure(t, testTenant, "the-secret", "the-value")
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			got, err := Get(ctx, "LATCHKEY_TEST_SECRET", tc.vaultEnv, "the-secret")
			if err != nil || got != "the-value" {
				t.Fatalf("Get = %q, %v", got, err)
			}
			if len(a.vaults) != 1 || a.vaults[0] != testVault {
				t.Fatalf("vaults asked %q", a.vaults)
			}
			tc.check(t, a, azArgs)
		})
	}
}
