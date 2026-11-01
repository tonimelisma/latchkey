package agent

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/coder/websocket"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/tonimelisma/latchkey/linux/internal/config"
	"github.com/tonimelisma/latchkey/linux/internal/devicekey"
	"github.com/tonimelisma/latchkey/relay/agentproto"
)

// Unpair connects once and says goodbye with user_disconnected, which makes the relay remove this
// server from the account (agent-protocol.md; FR-1027). The service's own connection, if any, is
// replaced and then closed as revoked.
func Unpair(ctx context.Context, s config.Settings, key *devicekey.Key, version string) error {
	target, err := agentURL(s.Relay)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, target, &websocket.DialOptions{Subprotocols: []string{agentproto.Subprotocol}})
	if err != nil {
		return err
	}
	defer func() { _ = ws.CloseNow() }()
	ws.SetReadLimit(agentproto.MaxFrameBytes)
	c := &conn{ws: ws}
	msg, err := c.read(ctx)
	if err != nil {
		return err
	}
	challenge, ok := msg.(*agentproto.Challenge)
	if !ok {
		return fmt.Errorf("expected challenge, got %s", msg.MessageType())
	}
	sig, err := key.Sign(challenge.Nonce, s.DeviceID)
	if err != nil {
		return err
	}
	if err := c.send(ctx, &agentproto.Hello{
		DeviceID: s.DeviceID, Signature: sig, AppVersion: version, OSVersion: osVersion(),
		Kind: agentproto.KindLinux, Tools: []*mcp.Tool{}, State: state(),
	}); err != nil {
		return err
	}
	if msg, err = c.read(ctx); err != nil {
		return err
	}
	if _, ok := msg.(*agentproto.Welcome); !ok {
		return fmt.Errorf("expected welcome, got %s", msg.MessageType())
	}
	if err := c.send(ctx, &agentproto.Goodbye{Reason: agentproto.ReasonUserDisconnected, State: state()}); err != nil {
		return err
	}
	for { // the relay answers by closing with 4002
		if _, err := c.read(ctx); err != nil {
			var ce closeError
			if errors.As(err, &ce) && ce.code == agentproto.CloseRevoked {
				return nil
			}
			return fmt.Errorf("the relay didn't confirm the removal: %w", err)
		}
	}
}
