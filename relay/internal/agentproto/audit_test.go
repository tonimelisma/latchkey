package agentproto_test

import (
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonimelisma/latchkey/relay/internal/agentproto"
)

// FR-632: call ids are "call_" and 26 characters of base32 (128 random bits), never repeated.
func TestCallIDsAreUniqueForAllTime(t *testing.T) {
	shape := regexp.MustCompile(`^call_[0-9A-HJKMNP-TV-Z]{26}$`)
	seen := map[string]bool{}
	for range 10000 {
		id := agentproto.NewCallID()
		require.Regexp(t, shape, id)
		require.False(t, seen[id], "call id %s made twice", id)
		seen[id] = true
	}
}

func TestAuditMessages(t *testing.T) {
	msg, err := agentproto.Decode([]byte(`{"type":"audit_request","id":"a1","since":5,"limit":10}`))
	require.NoError(t, err)
	req, ok := msg.(*agentproto.AuditRequest)
	require.True(t, ok)
	assert.Equal(t, "a1", req.ID)
	assert.EqualValues(t, 5, req.Since)
	assert.Equal(t, 10, req.Limit)
	assert.True(t, req.Valid())

	// An empty page is "entries": [], never null; the last page says "next_since": null.
	data, err := agentproto.Encode(&agentproto.Audit{ID: "a1"})
	require.NoError(t, err)
	assert.JSONEq(t, `{"type":"audit","id":"a1","entries":[],"next_since":null}`, string(data))

	for name, frame := range map[string]string{
		"missing id":     `{"type":"audit_request","since":5,"limit":10}`,
		"long id":        `{"type":"audit_request","id":"` + strings.Repeat("a", 129) + `","since":5,"limit":10}`,
		"bad outcome":    `{"type":"audit","id":"a","entries":[{"call_id":"","at":1,"tool":"x","outcome":"maybe","duration_ms":1}],"next_since":null}`,
		"entries absent": `{"type":"audit","id":"a","next_since":null}`,
	} {
		_, err := agentproto.Decode([]byte(frame))
		require.ErrorIs(t, err, agentproto.ErrProtocolViolation, name)
	}
	// An invalid since or limit is not a violation: the relay answers it with an empty page.
	for _, frame := range []string{
		`{"type":"audit_request","id":"a1","since":-1,"limit":10}`,
		`{"type":"audit_request","id":"a1","since":5,"limit":0}`,
		`{"type":"audit_request","id":"a1","since":5}`,
	} {
		msg, err = agentproto.Decode([]byte(frame))
		require.NoError(t, err, frame)
		assert.False(t, msg.(*agentproto.AuditRequest).Valid(), frame)
	}
	// A limit above the cap is cut to it.
	msg, err = agentproto.Decode([]byte(`{"type":"audit_request","id":"a1","since":5,"limit":5000}`))
	require.NoError(t, err)
	assert.Equal(t, agentproto.MaxAuditEntries, msg.(*agentproto.AuditRequest).PageSize())
}
