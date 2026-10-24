// Tests for latchkey.yml (`semgrep --test`): each `ruleid:` line must be reported, each `ok:` line
// must not.
package tests

import "net/http"

func fetch(guarded *http.Client, url string) {
	// ok: latchkey-outbound-http-guarded
	_, _ = guarded.Get(url)
	// ruleid: latchkey-outbound-http-guarded
	_, _ = http.Get(url)
	// ruleid: latchkey-outbound-http-guarded
	_, _ = http.DefaultClient.Get(url)
}
