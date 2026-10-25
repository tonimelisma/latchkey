// Package agentproto defines the messages of the Mac app ↔ relay agent protocol, v1
// (specs/001-core/contracts/agent-protocol.md).
package agentproto

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Subprotocol is the WebSocket subprotocol the agent must request.
const Subprotocol = "latchkey.v1"

// MaxFrameBytes is the largest frame either side accepts; larger frames close with 1009.
const MaxFrameBytes = 4 << 20

// Limits on a tool list (hello and tools messages): larger lists are a protocol violation.
const (
	MaxTools      = 256
	MaxToolsBytes = 512 << 10 // the list's JSON
)

// RelayToolLaptopStatus is answered by the relay itself; a Mac tool must not use the name.
const RelayToolLaptopStatus = "laptop_status"

// Close codes from the contract.
const (
	CloseNormal             = 1000
	CloseMessageTooBig      = 1009
	CloseAuthFailed         = 4001
	CloseRevoked            = 4002
	CloseReplaced           = 4003
	CloseUnsupportedVersion = 4004
	CloseProtocolViolation  = 4005
	CloseHandshakeTimeout   = 4006
)

var (
	// ErrProtocolViolation means the peer sent something the contract forbids (close 4005).
	ErrProtocolViolation = errors.New("agent protocol violation")
	// ErrBadSignature means the hello signature does not verify (close 4001).
	ErrBadSignature = errors.New("bad agent signature")
)

// Type is a message's "type" field.
type Type string

// Message types.
const (
	TypeChallenge Type = "challenge"
	TypeHello     Type = "hello"
	TypeWelcome   Type = "welcome"
	TypeState     Type = "state"
	TypeTools     Type = "tools"
	TypeProgress  Type = "progress"
	TypeResult    Type = "result"
	TypeGoodbye   Type = "goodbye"
	TypeCall      Type = "call"
	TypeCancel    Type = "cancel"
	TypeNotice    Type = "notice"
)

// AllTypes lists every message type in the contract.
var AllTypes = []Type{
	TypeChallenge, TypeHello, TypeWelcome, TypeState, TypeTools, TypeProgress,
	TypeResult, TypeGoodbye, TypeCall, TypeCancel, TypeNotice,
}

// Message is any protocol message.
type Message interface {
	MessageType() Type
}

// State is the Mac's reported condition, sent in hello, state, and goodbye.
type State struct {
	BatteryPercent   int       `json:"battery_percent"`
	PowerSource      string    `json:"power_source"`
	Charging         bool      `json:"charging"`
	TimeRemainingMin *int      `json:"time_remaining_min"`
	ThermalState     string    `json:"thermal_state"`
	LowPowerMode     bool      `json:"low_power_mode"`
	LidClosed        *bool     `json:"lid_closed"`
	TimeZone         *string   `json:"time_zone"`
	KeepAwake        string    `json:"keep_awake"`
	ObservedAt       time.Time `json:"observed_at"`
}

// Values of State.PowerSource.
const (
	PowerBattery = "battery"
	PowerAC      = "ac"
	PowerUPS     = "ups"
	PowerUnknown = "unknown"
)

// Values of State.KeepAwake.
const (
	KeepAwakeOn                = "on"
	KeepAwakeOffUser           = "off_user"
	KeepAwakeOffLowBattery     = "off_low_battery"
	KeepAwakeOffTooHot         = "off_too_hot"
	KeepAwakeOffHelperUnusable = "off_helper_unavailable"
)

// Values of Goodbye.Reason.
const (
	ReasonLowBattery       = "low_battery"
	ReasonTooHot           = "too_hot"
	ReasonUserQuit         = "user_quit"
	ReasonSystemSleep      = "system_sleep"
	ReasonSystemShutdown   = "system_shutdown"
	ReasonUserDisconnected = "user_disconnected"
)

// Values of Cancel.Reason.
const (
	CancelDeadline        = "deadline"
	CancelClientCancelled = "client_cancelled"
)

// Values of Notice.Kind.
const (
	NoticeAccountRecovered = "account_recovered"
	// NoticeClientAuthorized: a Claude client was given access; Client names it.
	NoticeClientAuthorized = "client_authorized"
)

// Challenge is the relay's first message.
type Challenge struct {
	Nonce      string    `json:"nonce"`
	ServerTime time.Time `json:"server_time"`
}

// Hello is the agent's answer to the challenge.
type Hello struct {
	DeviceID   string      `json:"device_id"`
	Signature  string      `json:"signature"`
	AppVersion string      `json:"app_version"`
	OSVersion  string      `json:"os_version"`
	Tools      []*mcp.Tool `json:"tools"`
	State      State       `json:"state"`
}

// Welcome accepts the agent.
type Welcome struct {
	HeartbeatIntervalS int       `json:"heartbeat_interval_s"`
	ServerTime         time.Time `json:"server_time"`
}

// StateUpdate is the heartbeat and change report.
type StateUpdate struct {
	State State `json:"state"`
}

// ToolsUpdate replaces the agent's tool list.
type ToolsUpdate struct {
	Tools []*mcp.Tool `json:"tools"`
}

// Progress reports progress on a long call.
type Progress struct {
	ID       string   `json:"id"`
	Progress float64  `json:"progress"`
	Total    *float64 `json:"total,omitempty"`
	Message  string   `json:"message,omitempty"`
}

// Result finishes a call. Content is an MCP content array, passed through unchanged.
type Result struct {
	ID                string          `json:"id"`
	Content           json.RawMessage `json:"content"`
	StructuredContent json.RawMessage `json:"structured_content,omitempty"`
	IsError           bool            `json:"is_error"`
}

// Goodbye precedes an intentional disconnect.
type Goodbye struct {
	Reason string `json:"reason"`
	State  State  `json:"state"`
}

// Call asks the agent to run a tool.
type Call struct {
	ID         string          `json:"id"`
	Tool       string          `json:"tool"`
	Arguments  json.RawMessage `json:"arguments"`
	DeadlineMS int64           `json:"deadline_ms"`
}

// Cancel withdraws a call.
type Cancel struct {
	ID     string `json:"id"`
	Reason string `json:"reason"`
}

// Notice tells the Owner something on the Mac.
type Notice struct {
	Kind   string    `json:"kind"`
	At     time.Time `json:"at"`
	Client string    `json:"client,omitempty"`
}

func (*Challenge) MessageType() Type   { return TypeChallenge }
func (*Hello) MessageType() Type       { return TypeHello }
func (*Welcome) MessageType() Type     { return TypeWelcome }
func (*StateUpdate) MessageType() Type { return TypeState }
func (*ToolsUpdate) MessageType() Type { return TypeTools }
func (*Progress) MessageType() Type    { return TypeProgress }
func (*Result) MessageType() Type      { return TypeResult }
func (*Goodbye) MessageType() Type     { return TypeGoodbye }
func (*Call) MessageType() Type        { return TypeCall }
func (*Cancel) MessageType() Type      { return TypeCancel }
func (*Notice) MessageType() Type      { return TypeNotice }

func newMessage(t Type) Message {
	switch t {
	case TypeChallenge:
		return &Challenge{}
	case TypeHello:
		return &Hello{}
	case TypeWelcome:
		return &Welcome{}
	case TypeState:
		return &StateUpdate{}
	case TypeTools:
		return &ToolsUpdate{}
	case TypeProgress:
		return &Progress{}
	case TypeResult:
		return &Result{}
	case TypeGoodbye:
		return &Goodbye{}
	case TypeCall:
		return &Call{}
	case TypeCancel:
		return &Cancel{}
	case TypeNotice:
		return &Notice{}
	}
	return nil
}

// DecodeHelloAuth reads only what proves who sent a hello: the device ID and the signature. The
// relay checks them before it parses anything else in the frame (Decode builds and validates the
// whole tool list), so a stranger can't make it do that work. A frame that isn't JSON or isn't a
// hello is ErrProtocolViolation.
func DecodeHelloAuth(data []byte) (deviceID, signature string, err error) {
	var env struct {
		Type      Type   `json:"type"`
		DeviceID  string `json:"device_id"`
		Signature string `json:"signature"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return "", "", fmt.Errorf("%w: %w", ErrProtocolViolation, err)
	}
	switch {
	case newMessage(env.Type) == nil:
		return "", "", fmt.Errorf("%w: unknown message type %q", ErrProtocolViolation, env.Type)
	case env.Type != TypeHello:
		return "", "", fmt.Errorf("%w: expected hello, got %s", ErrProtocolViolation, env.Type)
	}
	return env.DeviceID, env.Signature, nil
}

// Decode parses one text frame. Unknown fields are ignored; an unknown or missing type, a
// malformed body, or an invalid or oversized tool list is ErrProtocolViolation.
func Decode(data []byte) (Message, error) {
	var env struct {
		Type  Type            `json:"type"`
		Tools json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrProtocolViolation, err)
	}
	msg := newMessage(env.Type)
	if msg == nil {
		return nil, fmt.Errorf("%w: unknown message type %q", ErrProtocolViolation, env.Type)
	}
	if len(env.Tools) > MaxToolsBytes { // refused before the tools are built in memory
		return nil, fmt.Errorf("%w: tool list larger than %d KiB", ErrProtocolViolation, MaxToolsBytes>>10)
	}
	if err := json.Unmarshal(data, msg); err != nil {
		return nil, fmt.Errorf("%w: %s: %w", ErrProtocolViolation, env.Type, err)
	}
	switch m := msg.(type) {
	case *Hello:
		return msg, ValidateTools(m.Tools)
	case *ToolsUpdate:
		return msg, ValidateTools(m.Tools)
	}
	return msg, nil
}

// Encode serializes a message with its "type" field first.
func Encode(m Message) ([]byte, error) {
	body, err := json.Marshal(m)
	if err != nil {
		return nil, err
	}
	typ, err := json.Marshal(m.MessageType())
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	buf.WriteString(`{"type":`)
	buf.Write(typ)
	if len(body) > 2 { // body is a JSON object; splice its fields after "type"
		buf.WriteByte(',')
		buf.Write(body[1:])
	} else {
		buf.WriteByte('}')
	}
	return buf.Bytes(), nil
}

var toolName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,128}$`)

// ValidateTools enforces the contract's tool rules: valid unique names, none reserved by the relay,
// object input (and output) schemas, and nothing else the MCP SDK's AddTool refuses (it panics,
// for example on an invalid x-mcp-header annotation), so a Mac can't make the relay panic.
func ValidateTools(tools []*mcp.Tool) error {
	if len(tools) > MaxTools {
		return fmt.Errorf("%w: more than %d tools", ErrProtocolViolation, MaxTools)
	}
	seen := make(map[string]bool, len(tools))
	var trial *mcp.Server
	for _, t := range tools {
		switch {
		case t == nil || !toolName.MatchString(t.Name):
			return fmt.Errorf("%w: invalid tool name", ErrProtocolViolation)
		case t.Name == RelayToolLaptopStatus:
			return fmt.Errorf("%w: tool name %q is reserved by the relay", ErrProtocolViolation, t.Name)
		case seen[t.Name]:
			return fmt.Errorf("%w: duplicate tool %q", ErrProtocolViolation, t.Name)
		case !isObjectSchema(t.InputSchema):
			return fmt.Errorf("%w: tool %q: inputSchema must have type \"object\"", ErrProtocolViolation, t.Name)
		case t.OutputSchema != nil && !isObjectSchema(t.OutputSchema):
			return fmt.Errorf("%w: tool %q: outputSchema must have type \"object\"", ErrProtocolViolation, t.Name)
		}
		if trial == nil {
			trial = mcp.NewServer(&mcp.Implementation{Name: "validate", Version: "0"}, nil)
		}
		if err := TryAddTool(trial, t, refuseCalls); err != nil {
			return fmt.Errorf("%w: tool %q: %w", ErrProtocolViolation, t.Name, err)
		}
		seen[t.Name] = true
	}
	return nil
}

// TryAddTool adds t to srv, turning the SDK's panic on a tool it refuses into an error. It checks
// exactly what the pinned SDK checks, so the rules can't drift from it.
func TryAddTool(srv *mcp.Server, t *mcp.Tool, h mcp.ToolHandler) (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("refused by the MCP SDK: %v", p)
		}
	}()
	srv.AddTool(t, h)
	return nil
}

func refuseCalls(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
	return nil, errors.New("validation only")
}

func isObjectSchema(schema any) bool {
	m, ok := schema.(map[string]any)
	return ok && m["type"] == "object"
}
