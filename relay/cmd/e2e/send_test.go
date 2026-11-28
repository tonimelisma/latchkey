package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tonimelisma/latchkey/relay/reports"
)

func privateKey(t *testing.T) string {
	t.Helper()
	_, k, err := reports.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// vault stands in for Key Vault: each read is recorded and answered with answer.
func vault(t *testing.T, answer string, err error) *[]string {
	t.Helper()
	var asked []string
	old := vaultGet
	vaultGet = func(_ context.Context, env, vault, secret string) (string, error) {
		asked = append(asked, env+" "+vault+"/"+secret)
		return answer, err
	}
	t.Cleanup(func() { vaultGet = old })
	return &asked
}

// Regression (2026-11-27): with neither variable set, the sender read the key file
// ~/.config/latchkey-reports/developer.key instead of Key Vault, as latchkey-reports does.
func TestDeveloperPrivateReadsTheVaultNotTheOldKeyFile(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LATCHKEY_REPORTS_KEY", "")
	t.Setenv("LATCHKEY_REPORTS_KEY_FILE", "")
	dir := filepath.Join(home, ".config", "latchkey-reports")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "developer.key"), []byte(privateKey(t)), 0o600); err != nil {
		t.Fatal(err)
	}
	fromVault := privateKey(t)
	asked := vault(t, fromVault+"\n", nil)

	got, err := developerPrivate()
	if err != nil || got != fromVault {
		t.Fatalf("developerPrivate = %q, %v; want the vault's key", got, err)
	}
	if want := []string{"LATCHKEY_REPORTS_KEY kv-melisma-release/latchkey-reports-private-key"}; strings.Join(*asked, ",") != want[0] {
		t.Fatalf("vault asked %q, want %q", *asked, want)
	}
}

func TestDeveloperPrivateNamedSourcesWinOverTheVault(t *testing.T) {
	asked := vault(t, "", errors.New("the vault must not be asked"))
	fromEnv := privateKey(t)
	t.Setenv("LATCHKEY_REPORTS_KEY", fromEnv)
	t.Setenv("LATCHKEY_REPORTS_KEY_FILE", "")
	if got, err := developerPrivate(); err != nil || got != fromEnv {
		t.Fatalf("LATCHKEY_REPORTS_KEY: %q, %v", got, err)
	}
	fromFile := privateKey(t)
	f := filepath.Join(t.TempDir(), "named.key")
	if err := os.WriteFile(f, []byte(fromFile+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LATCHKEY_REPORTS_KEY", "")
	t.Setenv("LATCHKEY_REPORTS_KEY_FILE", f)
	if got, err := developerPrivate(); err != nil || got != fromFile {
		t.Fatalf("LATCHKEY_REPORTS_KEY_FILE: %q, %v", got, err)
	}
	if len(*asked) != 0 {
		t.Fatalf("vault asked %q", *asked)
	}
}

func TestDeveloperPrivateErrors(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("LATCHKEY_REPORTS_KEY", "")
	t.Setenv("LATCHKEY_REPORTS_KEY_FILE", "")
	vault(t, "", errors.New("Key Vault secret kv-melisma-release/latchkey-reports-private-key couldn't be read"))
	if _, err := developerPrivate(); err == nil || !strings.Contains(err.Error(), "--send is for the developer's own runs") ||
		!strings.Contains(err.Error(), "kv-melisma-release/latchkey-reports-private-key") {
		t.Fatalf("vault unreadable: %v", err)
	}
	vault(t, "not a key", nil)
	if _, err := developerPrivate(); err == nil || !strings.Contains(err.Error(), "kv-melisma-release/latchkey-reports-private-key") {
		t.Fatalf("not a key: %v", err)
	}
}
