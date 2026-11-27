// Package keyvault gives Latchkey's own tools and the hosted relay their secrets: an environment
// variable when it is set, otherwise the named secret from the owner's Azure Key Vault, read when
// the program needs it (managed from the private repository tonimelisma/secrets;
// docs/decisions.md, 2026-11-27). Nothing is written to disk and no value is ever printed.
//
// Who signs in to the vault:
//   - MELISMA_SECRETS_CLIENT_SECRET set (a Claude cloud session): the Entra app
//     cloud-sessions-reader with that client secret.
//   - LATCHKEY_KEYVAULT_AUTH=gce (the hosted relay on its Google VM): the Entra app host-pilvi,
//     with the VM's Google identity token as the assertion (no stored credential).
//   - Otherwise the Azure CLI's sign-in (`az login` on the owner's Mac).
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

// Not secret: the tenant and the apps that read the vaults.
const (
	tenantID           = "bd0d0de6-1ba6-42c2-84c6-8e447f1ef6ea"
	cloudSessionsAppID = "5154d2ee-bdf5-49cf-8643-8918b3e8c32c" // cloud-sessions-reader
	hostPilviAppID     = "ba787fd4-9049-4161-8ff0-a249be56357d" // host-pilvi
)

// metadataIdentityURL is where a Google VM's metadata server hands out the VM account's ID token
// for Entra's token exchange. A variable so tests can point it at a stand-in.
var metadataIdentityURL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=api://AzureADTokenExchange&format=full"

// How the vault is signed in to, chosen from the environment.
const (
	authCloudSession = "cloud-session client secret (MELISMA_SECRETS_CLIENT_SECRET)"
	authGCE          = "the Google VM's identity (LATCHKEY_KEYVAULT_AUTH=gce)"
	authCLI          = "the Azure CLI's sign-in (az login)"
)

func authKind(getenv func(string) string) string {
	switch {
	case getenv("MELISMA_SECRETS_CLIENT_SECRET") != "":
		return authCloudSession
	case getenv("LATCHKEY_KEYVAULT_AUTH") == "gce":
		return authGCE
	}
	return authCLI
}

// credential signs in as authKind says.
func credential(getenv func(string) string) (azcore.TokenCredential, error) {
	switch authKind(getenv) {
	case authCloudSession:
		return azidentity.NewClientSecretCredential(tenantID, cloudSessionsAppID, getenv("MELISMA_SECRETS_CLIENT_SECRET"), nil)
	case authGCE:
		return azidentity.NewClientAssertionCredential(tenantID, hostPilviAppID, googleIDToken, nil)
	}
	return azidentity.NewAzureCLICredential(&azidentity.AzureCLICredentialOptions{TenantID: tenantID})
}

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

// Get returns the environment variable env when it is set, otherwise secret from the vault (for
// example "kv-melisma-dev"). A value read from the vault is kept for the rest of the process.
// The error names the variable, the secret and how the vault was signed in to, never a value.
func Get(ctx context.Context, env, vault, secret string) (string, error) {
	if v := os.Getenv(env); v != "" {
		return v, nil
	}
	ref := vault + "/" + secret
	mu.Lock()
	defer mu.Unlock()
	if v, ok := cache[ref]; ok {
		return v, nil
	}
	v, err := fetch(ctx, os.Getenv, vault, secret)
	if err != nil {
		return "", fmt.Errorf("%s isn't set, and Key Vault secret %s couldn't be read with %s: %w", env, ref, authKind(os.Getenv), err)
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
	client, err := azsecrets.NewClient(vaultURL(vault), cred, nil)
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
