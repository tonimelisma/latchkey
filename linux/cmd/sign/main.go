// Command sign writes the signature of each release program next to it, as file.sig (base64
// Ed25519 over update.Signed: architecture, version, and SHA-256), for the server program's
// update check (spec 010 plan D12). The key is the base64 seed in SERVER_SIGNING_KEY; it must
// match the public key built into the program.
//
//	sign VERSION build/latchkey-linux-amd64 build/latchkey-linux-arm64
package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/tonimelisma/latchkey/linux/internal/update"
)

func main() {
	if len(os.Args) < 3 {
		fail("usage: sign VERSION FILE…")
	}
	seed, err := base64.StdEncoding.DecodeString(os.Getenv("SERVER_SIGNING_KEY"))
	if err != nil || len(seed) != ed25519.SeedSize {
		fail("SERVER_SIGNING_KEY must be the base64 Ed25519 seed (see .env)")
	}
	key := ed25519.NewKeyFromSeed(seed)
	if !bytes.Equal(key.Public().(ed25519.PublicKey), update.PublicKey()) {
		fail("SERVER_SIGNING_KEY doesn't match the public key in linux/internal/update/key.go")
	}
	version := os.Args[1]
	for _, path := range os.Args[2:] {
		arch, ok := strings.CutPrefix(filepath.Base(path), "latchkey-linux-")
		if !ok {
			fail(path + " isn't named latchkey-linux-<arch>")
		}
		data, err := os.ReadFile(path) //nolint:gosec // the release files named on the command line
		if err != nil {
			fail(err.Error())
		}
		sig := base64.StdEncoding.EncodeToString(ed25519.Sign(key, update.Signed(arch, version, data))) + "\n"
		if err := os.WriteFile(path+".sig", []byte(sig), 0o644); err != nil { //nolint:gosec // a signature is public, published beside the program
			fail(err.Error())
		}
		if err := update.Verify(update.PublicKey(), arch, version, data, []byte(sig)); err != nil {
			fail(err.Error())
		}
	}
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "sign: "+msg)
	os.Exit(1)
}
