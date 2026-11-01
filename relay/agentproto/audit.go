package agentproto

import (
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"fmt"
)

// Added 2026-10-27 (FR-632, FR-634): call ids unique for all time, and the audit comparison.
const (
	TypeAuditRequest Type = "audit_request"
	TypeAudit        Type = "audit"
)

// FeatureAudit in Hello.Features says the agent understands audit_request and audit.
const FeatureAudit = "audit"

// MaxAuditEntries is the most entries one audit page holds; a larger limit is cut to it.
const MaxAuditEntries = 1000

// maxAuditRequestID bounds the id the relay echoes back.
const maxAuditRequestID = 128

// callIDEncoding is Crockford's base32 alphabet (no I, L, O, U), upper case, unpadded: 128 bits
// make 26 characters.
var callIDEncoding = base32.NewEncoding("0123456789ABCDEFGHJKMNPQRSTVWXYZ").WithPadding(base32.NoPadding)

// NewCallID makes a call id unique for all time (FR-632): "call_" and 128 random bits.
func NewCallID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b) // never fails (crypto/rand)
	return "call_" + callIDEncoding.EncodeToString(b)
}

// AuditRequest asks for one page of the relay's audit of this Mac: entries at or after Since
// (milliseconds since 1970), at most Limit of them.
type AuditRequest struct {
	ID    string `json:"id"`
	Since int64  `json:"since"`
	Limit int    `json:"limit"`
}

// Valid reports whether Since and Limit can be answered; an invalid request gets an empty page.
func (r *AuditRequest) Valid() bool { return r.Since >= 0 && r.Limit >= 1 }

// PageSize is Limit cut to MaxAuditEntries.
func (r *AuditRequest) PageSize() int { return min(r.Limit, MaxAuditEntries) }

// AuditEntry is one row of the relay's audit as the Mac sees it. CallID is "" for calls from
// before call ids.
type AuditEntry struct {
	CallID     string `json:"call_id"`
	At         int64  `json:"at"`
	Tool       string `json:"tool"`
	Outcome    string `json:"outcome"`
	DurationMS int64  `json:"duration_ms"`
}

// Audit answers an AuditRequest. NextSince is the since of the next page, nil when there is none.
type Audit struct {
	ID        string       `json:"id"`
	Entries   []AuditEntry `json:"entries"`
	NextSince *int64       `json:"next_since"`
}

func (*AuditRequest) MessageType() Type { return TypeAuditRequest }
func (*Audit) MessageType() Type        { return TypeAudit }

// MarshalJSON writes an empty page as "entries": [], never null.
func (a *Audit) MarshalJSON() ([]byte, error) {
	type plain Audit
	p := plain(*a)
	if p.Entries == nil {
		p.Entries = []AuditEntry{}
	}
	return json.Marshal(p)
}

var auditOutcomes = map[string]bool{"ok": true, "error": true, "timeout": true, "offline": true}

func validateAuditRequest(r *AuditRequest) error {
	if r.ID == "" || len(r.ID) > maxAuditRequestID {
		return fmt.Errorf("%w: audit_request needs an id of 1 to %d bytes", ErrProtocolViolation, maxAuditRequestID)
	}
	return nil
}

func validateAudit(a *Audit) error {
	switch {
	case a.ID == "":
		return fmt.Errorf("%w: audit needs an id", ErrProtocolViolation)
	case a.Entries == nil:
		return fmt.Errorf("%w: audit entries must be a list", ErrProtocolViolation)
	case len(a.Entries) > MaxAuditEntries:
		return fmt.Errorf("%w: more than %d audit entries", ErrProtocolViolation, MaxAuditEntries)
	}
	for _, e := range a.Entries {
		if !auditOutcomes[e.Outcome] {
			return fmt.Errorf("%w: unknown audit outcome %q", ErrProtocolViolation, e.Outcome)
		}
	}
	return nil
}
