package agentproto

import "encoding/json"

// Added 2026-11-25 (spec 014 FR-1443 to FR-1445): the relay asks a machine for its part of a
// problem report through an ordinary call of a tool no machine may list, so no new message type
// reaches a relay or an app that doesn't know it.
const (
	// ReportPartTool is the tool the relay calls for a machine's part; reserved (ValidateTools).
	ReportPartTool = "latchkey_report_part"
	// FeatureReportPart in Hello.Features says the machine answers ReportPartTool.
	FeatureReportPart = "report_part"
	// MaxReportPartBytes is what the relay asks a part to fit in: under MaxFrameBytes with room
	// for the result's envelope and JSON escaping.
	MaxReportPartBytes = 3_500_000
)

// ReportPartArgs are the call's arguments (contract feedback-intake.md).
type ReportPartArgs struct {
	Report   string   `json:"report"`
	Since    int64    `json:"since"` // milliseconds since 1970
	Until    int64    `json:"until"`
	CallIDs  []string `json:"call_ids"`
	Pages    []string `json:"pages"`
	MaxBytes int      `json:"max_bytes"`
}

// ReportPart is a machine's answer, carried as the text of the result's one text content.
type ReportPart struct {
	Log   []PartLogLine   `json:"log,omitempty"`
	Calls []PartCall      `json:"calls,omitempty"`
	Pages []PartPage      `json:"pages,omitempty"`
	Notes []string        `json:"notes,omitempty"`
	Extra json.RawMessage `json:"extra,omitempty"`
}

// PartLogLine is one line of Latchkey's log on the machine.
type PartLogLine struct {
	Time     string `json:"time"`
	Category string `json:"category,omitempty"`
	Error    bool   `json:"error,omitempty"`
	Text     string `json:"text"`
}

// PartCall is the machine's own trace of one of the chat's calls.
type PartCall struct {
	CallID     string          `json:"call_id"`
	Time       string          `json:"time"`
	Tool       string          `json:"tool"`
	Result     json.RawMessage `json:"result,omitempty"`
	IsError    bool            `json:"is_error,omitempty"`
	DurationMS int64           `json:"duration_ms"`
}

// PartPage describes one page of the chat's (FR-1447); kept as JSON the relay passes on as is.
type PartPage = json.RawMessage
