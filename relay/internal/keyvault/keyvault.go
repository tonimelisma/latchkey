// Package keyvault gives Latchkey's own tools and the hosted relay their secrets: an environment
// variable when it is set, otherwise the named secret from an Azure Key Vault, read when the
// program needs it (docs/decisions.md, 2026-11-27). Nothing is written to disk and no value is
// ever printed.
//
// Which tenant, app and vaults: only the environment says, with no built-in values
// (docs/development.md, "Maintainer setup"). AZURE_TENANT_ID is the Entra tenant on every path;
// a vault's name is in the variable the caller names (HostsVault, DevVault, ReleaseVault). Who
// signs in:
//   - MELISMA_SECRETS_CLIENT_SECRET set (a Claude cloud session): the Entra app AZURE_CLIENT_ID
//     with that client secret.
//   - LATCHKEY_KEYVAULT_AUTH=gce (a relay on a Google VM): the Entra app AZURE_CLIENT_ID, with
//     the VM's Google identity token as the assertion (no stored credential).
//   - Otherwise the Azure CLI's sign-in (`az login` on a developer's Mac) in AZURE_TENANT_ID.
//
// A variable that is needed and missing is an error that names it, never a value.
package keyvault

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/security/keyvault/azsecrets"
)

// The variables that name the vaults, for Get's vaultEnv.
const (
	HostsVault   = "LATCHKEY_KEYVAULT_HOSTS"   // the hosted servers' secrets (the relay's email key)
	DevVault     = "LATCHKEY_KEYVAULT_DEV"     // development secrets (the intake's developer token)
	ReleaseVault = "LATCHKEY_KEYVAULT_RELEASE" // release secrets (the problem reports' private key)
)

// The sign-in's variables.
const (
	tenantEnv       = "AZURE_TENANT_ID"
	clientEnv       = "AZURE_CLIENT_ID"
	clientSecretEnv = "MELISMA_SECRETS_CLIENT_SECRET"
	authEnv         = "LATCHKEY_KEYVAULT_AUTH"
)

// metadataIdentityURL is where a Google VM's metadata server hands out the VM account's ID token
// for Entra's token exchange. A variable so tests can point it at a stand-in.
var metadataIdentityURL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=api://AzureADTokenExchange&format=full"

// How the vault is signed in to, chosen from the environment.
const (
	authCloudSession = "the cloud session's client secret (MELISMA_SECRETS_CLIENT_SECRET)"
	authGCE          = "the Google VM's identity (LATCHKEY_KEYVAULT_AUTH=gce)"
	authCLI          = "the Azure CLI's sign-in (az login)"
)

func authKind(getenv func(string) string) string {
	switch {
	case getenv(clientSecretEnv) != "":
		return authCloudSession
	case getenv(authEnv) == "gce":
		return authGCE
	}
	return authCLI
}

// required is the variable's value, or an error naming it.
func required(getenv func(string) string, name, kind string) (string, error) {
	if v := strings.TrimSpace(getenv(name)); v != "" {
		return v, nil
	}
	return "", fmt.Errorf("%s isn't set: signing in to Key Vault with %s needs it", name, kind)
}

// credential signs in as authKind says, in the tenant and as the app the environment names.
func credential(getenv func(string) string) (azcore.TokenCredential, error) {
	kind := authKind(getenv)
	tenant, err := required(getenv, tenantEnv, kind)
	if err != nil {
		return nil, err
	}
	if kind == authCLI {
		return azidentity.NewAzureCLICredential(&azidentity.AzureCLICredentialOptions{TenantID: tenant})
	}
	client, err := required(getenv, clientEnv, kind)
	if err != nil {
		return nil, err
	}
	var opts azcore.ClientOptions
	standIn := testOptions != nil
	if standIn {
		opts = *testOptions
	}
	if kind == authCloudSession {
		return azidentity.NewClientSecretCredential(tenant, client, getenv(clientSecretEnv),
			&azidentity.ClientSecretCredentialOptions{ClientOptions: opts, DisableInstanceDiscovery: standIn})
	}
	return azidentity.NewClientAssertionCredential(tenant, client, googleIDToken,
		&azidentity.ClientAssertionCredentialOptions{ClientOptions: opts, DisableInstanceDiscovery: standIn})
}

// testOptions, set only by tests, sends Entra's and the vault's requests to local stand-ins.
var testOptions *azcore.ClientOptions

// vaultURL is a vault's address. A variable so tests never reach Azure.
var vaultURL = func(vault string) string { return "https://" + vault + ".vault.azure.net" }

var metadataClient = &http.Client{Timeout: 10 * time.Second}

// googleIDToken asks the VM's metadata server for its account's ID token.
func googleIDToken(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, metadataIdentityURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	resp, err := metadataClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("the metadata server: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
	if err != nil {
		return "", fmt.Errorf("the metadata server: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("the metadata server answered %s", resp.Status)
	}
	t := strings.TrimSpace(string(body))
	if t == "" {
		return "", errors.New("the metadata server answered no identity token")
	}
	return t, nil
}

var (
	mu    sync.Mutex
	cred  azcore.TokenCredential
	cache = map[string]string{}
)

// Get returns the environment variable env when it is set, otherwise secret from the vault the
// variable vaultEnv names (HostsVault, DevVault or ReleaseVault). A value read from the vault is
// kept for the rest of the process. The error names the variables, the secret and how the vault
// was signed in to, never a value.
func Get(ctx context.Context, env, vaultEnv, secret string) (string, error) {
	if v := os.Getenv(env); v != "" {
		return v, nil
	}
	vault := strings.TrimSpace(os.Getenv(vaultEnv))
	if vault == "" {
		return "", fmt.Errorf("%s isn't set, and neither is %s, the Key Vault to read secret %s from", env, vaultEnv, secret)
	}
	ref := vault + "/" + secret
	mu.Lock()
	defer mu.Unlock()
	if v, ok := cache[ref]; ok {
		return v, nil
	}
	v, err := fetch(ctx, os.Getenv, vault, secret)
	if err != nil {
		return "", fmt.Errorf("%s isn't set, and secret %s in the Key Vault %s names couldn't be read with %s: %w", env, secret, vaultEnv, authKind(os.Getenv), err)
	}
	cache[ref] = v
	return v, nil
}

// fetch reads one secret from the vault; the caller holds mu.
func fetch(ctx context.Context, getenv func(string) string, vault, secret string) (string, error) {
	if cred == nil {
		c, err := credential(getenv)
		if err != nil {
			return "", err
		}
		cred = c
	}
	var opts *azsecrets.ClientOptions
	if testOptions != nil {
		opts = &azsecrets.ClientOptions{ClientOptions: *testOptions, DisableChallengeResourceVerification: true}
	}
	client, err := azsecrets.NewClient(vaultURL(vault), cred, opts)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := client.GetSecret(ctx, secret, "", nil)
	if err != nil {
		return "", err
	}
	if resp.Value == nil || *resp.Value == "" {
		return "", errors.New("the secret is empty")
	}
	return *resp.Value, nil
}

// ReportsKey is the developer's private problem-report key as text (base64, as `latchkey-reports
// keygen` writes it), for latchkey-reports and the e2e eval sender: LATCHKEY_REPORTS_KEY when it
// is set, otherwise the file LATCHKEY_REPORTS_KEY_FILE names (an explicit override), otherwise
// secret latchkey-reports-private-key in the release vault (ReleaseVault) through get (Get; a
// stand-in in tests). No file is read that nobody named (docs/decisions.md, 2026-11-27).
func ReportsKey(ctx context.Context, get func(ctx context.Context, env, vaultEnv, secret string) (string, error)) (string, error) {
	k := os.Getenv("LATCHKEY_REPORTS_KEY")
	if f := os.Getenv("LATCHKEY_REPORTS_KEY_FILE"); k == "" && f != "" {
		b, err := os.ReadFile(f) //nolint:gosec // the developer names the file
		if err != nil {
			return "", err
		}
		k = string(b)
	}
	if strings.TrimSpace(k) == "" {
		var err error
		if k, err = get(ctx, "LATCHKEY_REPORTS_KEY", ReleaseVault, "latchkey-reports-private-key"); err != nil {
			return "", err
		}
	}
	return strings.TrimSpace(k), nil
}
