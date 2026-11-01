// Package setup pairs a server with the Owner's account and installs or removes its service
// (spec 010 FR-1021, FR-1022, FR-1026, FR-1027; contracts/server-program.md).
package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Pairing is what the relay answers when a server asks to be paired.
type Pairing struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri"`
	Interval        int    `json:"interval"`
	ExpiresIn       int    `json:"expires_in"`
}

// Paired is the outcome.
type Paired struct {
	DeviceID string `json:"device_id"`
	Name     string `json:"name"`
}

var client = &http.Client{Timeout: 20 * time.Second}

func post(ctx context.Context, url string, body any) (int, []byte, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return 0, nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	out, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode, out, err
}

// Start asks the relay for a pairing code.
func Start(ctx context.Context, relay, name, publicKey string) (Pairing, error) {
	status, body, err := post(ctx, strings.TrimRight(relay, "/")+"/pair/device",
		map[string]string{"name": name, "kind": "linux", "public_key": publicKey})
	if err != nil {
		return Pairing{}, fmt.Errorf("couldn't reach the relay at %s: %w", relay, err)
	}
	if status != http.StatusOK {
		return Pairing{}, fmt.Errorf("the relay refused: %s", relayError(status, body))
	}
	var p Pairing
	if err := json.Unmarshal(body, &p); err != nil || p.DeviceCode == "" || p.UserCode == "" {
		return Pairing{}, fmt.Errorf("the relay at %s didn't answer like a Latchkey relay", relay)
	}
	if p.Interval <= 0 {
		p.Interval = 5
	}
	return p, nil
}

func relayError(status int, body []byte) string {
	var e struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(body, &e) == nil && e.Error != "" {
		return e.Error
	}
	return fmt.Sprintf("HTTP %d", status)
}

// ErrExpired: the code wasn't approved in time.
var ErrExpired = errors.New("the code expired before it was approved; run the setup again")

// Wait polls until the Owner approves the code, it expires, or ctx ends.
func Wait(ctx context.Context, relay string, p Pairing) (Paired, error) {
	interval := time.Duration(p.Interval) * time.Second
	deadline := time.Now().Add(time.Duration(p.ExpiresIn) * time.Second)
	for {
		t := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			t.Stop()
			return Paired{}, ctx.Err()
		case <-t.C:
		}
		status, body, err := post(ctx, strings.TrimRight(relay, "/")+"/pair/device/token", map[string]string{"device_code": p.DeviceCode})
		if err != nil {
			if time.Now().After(deadline) {
				return Paired{}, ErrExpired
			}
			continue // a network hiccup: ask again
		}
		if status == http.StatusOK {
			var out Paired
			if err := json.Unmarshal(body, &out); err != nil || out.DeviceID == "" {
				return Paired{}, errors.New("the relay's answer had no device ID")
			}
			return out, nil
		}
		switch relayError(status, body) {
		case "authorization_pending":
		case "slow_down":
			interval += 5 * time.Second
		case "expired_token":
			return Paired{}, ErrExpired
		default:
			return Paired{}, fmt.Errorf("the relay refused: %s", relayError(status, body))
		}
	}
}
