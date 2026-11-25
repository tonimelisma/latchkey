package agentproto

import (
	"errors"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Spec 014 FR-1445: no machine may offer the tool the relay uses to ask for a report's part, so
// Claude can never be shown it.
func TestNoMachineMayOfferTheReportPartTool(t *testing.T) {
	err := ValidateTools([]*mcp.Tool{{Name: ReportPartTool, InputSchema: map[string]any{"type": "object"}}})
	if !errors.Is(err, ErrProtocolViolation) {
		t.Fatalf("err = %v, want a protocol violation", err)
	}
}
