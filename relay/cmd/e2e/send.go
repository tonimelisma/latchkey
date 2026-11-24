package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/evals"
	"github.com/tonimelisma/latchkey/relay/reports"
)

// sendCmd seals a weekly result to the developer's key and sends it to the developer's intake
// (FR-1530), only when the person running the tests asked (weekly-eval.sh --send). The key and
// intake are Latchkey's developer's unless LATCHKEY_DEVELOPER_KEY and LATCHKEY_INTAKE_URL name a
// fork's.
func sendCmd(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: e2e send <result.json>")
	}
	data, err := os.ReadFile(args[0]) //nolint:gosec // the result file the person named
	if err != nil {
		return err
	}
	var r evals.Result
	if err := json.Unmarshal(data, &r); err != nil {
		return err
	}
	if r.Kind != "eval" {
		return errors.New("not a weekly result")
	}
	key := reports.DefaultDeveloperKey()
	if k := strings.TrimSpace(os.Getenv("LATCHKEY_DEVELOPER_KEY")); k != "" {
		key = k
	}
	pk, err := reports.PublicKey(key)
	if err != nil {
		return err
	}
	intake := reports.DefaultIntakeURL
	if u := strings.TrimSpace(os.Getenv("LATCHKEY_INTAKE_URL")); u != "" {
		intake = u
	}
	parts, err := evals.SealParts(pk, r)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 30 * time.Second}
	for i, sealed := range parts {
		hour := reports.Hour(time.Now())
		nonce := reports.Prove(sealed, hour, reports.WorkBits)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		req, err := http.NewRequestWithContext(ctx, //nolint:gosec // the developer's intake, or a fork's named by its developer
			http.MethodPost, strings.TrimRight(intake, "/")+"/v1/reports", bytes.NewReader(sealed))
		if err != nil {
			cancel()
			return err
		}
		req.Header.Set("Content-Type", "application/octet-stream")
		req.Header.Set("Latchkey-Work-Hour", hour)
		req.Header.Set("Latchkey-Work-Nonce", strconv.FormatUint(nonce, 10))
		resp, err := client.Do(req) //nolint:gosec // the developer's intake
		if err != nil {
			cancel()
			return fmt.Errorf("part %d: %w", i+1, err)
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		_ = resp.Body.Close()
		cancel()
		if resp.StatusCode/100 != 2 {
			return fmt.Errorf("part %d: the intake answered %s: %s", i+1, resp.Status, strings.TrimSpace(string(body)))
		}
	}
	fmt.Printf("sent %s to %s in %d part(s), sealed to the developer's key\n", r.Run, intake, len(parts))
	return nil
}
