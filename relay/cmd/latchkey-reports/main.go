// latchkey-reports is the developer's command for problem reports (spec 014 FR-1423, FR-1430):
//
//	latchkey-reports keygen <private-key-file>  makes a key pair; prints the public key
//	latchkey-reports list                       the waiting problem reports, opened (summaries)
//	latchkey-reports show <id> [-out <folder>]  one report written as files outside the repository
//	latchkey-reports evals                        the test Mac results sent (spec 015 FR-1531)
//	latchkey-reports delete <id>...             deletes dispositioned reports (nothing is kept)
//
// It reads the intake's address from LATCHKEY_INTAKE_URL (default Latchkey's), the developer's
// token from LATCHKEY_INTAKE_TOKEN (left out where a network proxy adds it, as in a cloud
// session), and the private key (base64) from LATCHKEY_REPORTS_KEY or the file named by
// LATCHKEY_REPORTS_KEY_FILE. Report contents go only to this command's output.
package main

import (
	"context"
	"crypto/hpke"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/reports"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "latchkey-reports:", err)
		os.Exit(1)
	}
}

const usage = "usage: latchkey-reports keygen <private-key-file> | list | show <id> [-out <folder>] | evals | delete <id> [<id>]"

func run(args []string) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	switch args[0] {
	case "keygen":
		if len(args) != 2 {
			return errors.New(usage)
		}
		pub, priv, err := reports.GenerateKey()
		if err != nil {
			return err
		}
		if err := os.WriteFile(args[1], []byte(priv+"\n"), 0o600); err != nil { //nolint:gosec // the developer names the file
			return err
		}
		fmt.Println(pub)
		return nil
	case "list":
		return list()
	case "show":
		return show(args[1:])
	case "evals":
		return evalsCmd(args[1:], time.Now(), os.Stdout)
	case "delete":
		if len(args) < 2 {
			return errors.New(usage)
		}
		for _, id := range args[1:] {
			if err := call(http.MethodDelete, "/v1/reports/"+id, nil); err != nil {
				return fmt.Errorf("%s: %w", id, err)
			}
			fmt.Println("deleted", id)
		}
		return nil
	}
	return errors.New(usage)
}

func intakeURL() string {
	if u := strings.TrimSpace(os.Getenv("LATCHKEY_INTAKE_URL")); u != "" {
		return strings.TrimRight(u, "/")
	}
	return reports.DefaultIntakeURL
}

var client = &http.Client{Timeout: 2 * time.Minute} // reports reach 5 MB

func call(method, path string, out *[]byte) error {
	req, err := http.NewRequestWithContext(context.Background(), method, intakeURL()+path, nil) //nolint:gosec // the developer's own intake
	if err != nil {
		return err
	}
	if t := strings.TrimSpace(os.Getenv("LATCHKEY_INTAKE_TOKEN")); t != "" {
		req.Header.Set("Authorization", "Bearer "+t)
	}
	resp, err := client.Do(req) //nolint:gosec // the developer's own intake
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(resp.Body, reports.MaxSealed*2+1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("the intake answered %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	if out != nil {
		*out = body
	}
	return nil
}

func key() (hpke.PrivateKey, error) {
	k, err := keyText()
	if err != nil {
		return nil, err
	}
	return reports.PrivateKey(k)
}

// keyText is the developer's private key as text (base64).
func keyText() (string, error) {
	k := os.Getenv("LATCHKEY_REPORTS_KEY")
	if f := os.Getenv("LATCHKEY_REPORTS_KEY_FILE"); k == "" && f != "" {
		b, err := os.ReadFile(f) //nolint:gosec // the developer names the file
		if err != nil {
			return "", err
		}
		k = string(b)
	}
	if strings.TrimSpace(k) == "" {
		return "", errors.New("set LATCHKEY_REPORTS_KEY (or LATCHKEY_REPORTS_KEY_FILE) to the developer's private key")
	}
	return strings.TrimSpace(k), nil
}

// opened is one waiting report as the developer reads it.
type opened struct {
	ID      string    `json:"id"`
	Arrived time.Time `json:"arrived"`
	Report  any       `json:"report,omitempty"` // summarized: show writes the rest
	Error   string    `json:"error,omitempty"`
}

// entry is one waiting entry, opened: a problem report or a part of a weekly result.
type entry struct {
	ID      string
	Arrived time.Time
	Plain   []byte
	Err     error
}

func fetch() ([]entry, error) {
	k, err := key()
	if err != nil {
		return nil, err
	}
	var body []byte
	if err := call(http.MethodGet, "/v1/reports", &body); err != nil {
		return nil, err
	}
	var waiting []struct {
		ID      string    `json:"id"`
		Arrived time.Time `json:"arrived"`
	}
	if err := json.Unmarshal(body, &waiting); err != nil {
		return nil, err
	}
	out := make([]entry, 0, len(waiting))
	for _, w := range waiting {
		e := entry{ID: w.ID, Arrived: w.Arrived}
		var sealed []byte
		if err := call(http.MethodGet, "/v1/reports/"+w.ID, &sealed); err != nil {
			e.Err = err
		} else {
			e.Plain, e.Err = reports.OpenRaw(k, sealed)
		}
		out = append(out, e)
	}
	return out, nil
}

// list prints the waiting problem reports; weekly results are under evals.
func list() error {
	entries, err := fetch()
	if err != nil {
		return err
	}
	out := []opened{}
	for _, e := range entries {
		o := opened{ID: e.ID, Arrived: e.Arrived}
		switch {
		case e.Err != nil:
			o.Error = e.Err.Error() // junk or another key's: delete it after a look
		case reports.Kind(e.Plain) == "eval":
			continue
		default:
			var r reports.Report
			if err := json.Unmarshal(e.Plain, &r); err != nil {
				o.Error = err.Error()
			} else {
				o.Report = summarized(r)
			}
		}
		out = append(out, o)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}
