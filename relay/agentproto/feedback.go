package agentproto

import (
	"encoding/json"
	"fmt"
	"regexp"
	"time"
	"unicode/utf8"
)

// Added 2026-11-16 (spec 001 FR-690 to FR-695): Claude's feedback reports, kept by the relay and
// saved as files on the Mac.
const (
	TypeFeedback      Type = "feedback"       // relay → agent: reports to save
	TypeFeedbackSaved Type = "feedback_saved" // agent → relay: the reports it saved
)

// FeatureFeedback in Hello.Features says the agent understands feedback and feedback_saved.
const FeatureFeedback = "feedback"

// RelayToolFeedback is the relay's own tool for Claude's reports (FR-690); no agent may offer a
// tool of that name.
const RelayToolFeedback = "feedback"

// Limits of one report and of one feedback message.
const (
	MaxFeedbackSummary = 500
	MaxFeedbackDetails = 20_000
	MaxFeedbackName    = 200 // client and machine
	MaxFeedbackReports = 50
)

// FeedbackReport is one report Claude filed.
type FeedbackReport struct {
	ID      string    `json:"id"`
	At      time.Time `json:"at"`
	Client  string    `json:"client"`
	Machine string    `json:"machine"`
	Summary string    `json:"summary"`
	Details string    `json:"details"`
}

// Feedback carries reports the agent hasn't saved yet, oldest first.
type Feedback struct {
	Reports []FeedbackReport `json:"reports"`
}

// FeedbackSaved names the reports the agent saved.
type FeedbackSaved struct {
	IDs []string `json:"ids"`
}

func (*Feedback) MessageType() Type      { return TypeFeedback }
func (*FeedbackSaved) MessageType() Type { return TypeFeedbackSaved }

// feedbackID is "fb_" and 26 characters of the call id alphabet.
var feedbackID = regexp.MustCompile(`^fb_[0-9A-Z]{26}$`)

// NewFeedbackID makes a report id unique for all time.
func NewFeedbackID() string { return "fb_" + NewCallID()[len("call_"):] }

// ValidFeedbackID reports whether id has the shape of a report's id.
func ValidFeedbackID(id string) bool { return feedbackID.MatchString(id) }

// ValidateFeedbackReport enforces the limits of one report.
func ValidateFeedbackReport(r FeedbackReport) error {
	switch {
	case !ValidFeedbackID(r.ID):
		return fmt.Errorf("%w: invalid feedback id", ErrProtocolViolation)
	case r.At.IsZero():
		return fmt.Errorf("%w: feedback without a time", ErrProtocolViolation)
	case r.Summary == "" || utf8.RuneCountInString(r.Summary) > MaxFeedbackSummary:
		return fmt.Errorf("%w: feedback summary empty or too long", ErrProtocolViolation)
	case utf8.RuneCountInString(r.Details) > MaxFeedbackDetails:
		return fmt.Errorf("%w: feedback details too long", ErrProtocolViolation)
	case utf8.RuneCountInString(r.Client) > MaxFeedbackName || utf8.RuneCountInString(r.Machine) > MaxFeedbackName:
		return fmt.Errorf("%w: feedback client or machine too long", ErrProtocolViolation)
	}
	return nil
}

func validateFeedback(m *Feedback) error {
	if len(m.Reports) > MaxFeedbackReports {
		return fmt.Errorf("%w: more than %d feedback reports", ErrProtocolViolation, MaxFeedbackReports)
	}
	for _, r := range m.Reports {
		if err := ValidateFeedbackReport(r); err != nil {
			return err
		}
	}
	return nil
}

func validateFeedbackSaved(m *FeedbackSaved) error {
	if len(m.IDs) > MaxFeedbackReports {
		return fmt.Errorf("%w: more than %d saved feedback ids", ErrProtocolViolation, MaxFeedbackReports)
	}
	for _, id := range m.IDs {
		if !ValidFeedbackID(id) {
			return fmt.Errorf("%w: invalid feedback id", ErrProtocolViolation)
		}
	}
	return nil
}

// MarshalJSON writes no reports as "reports": [], never null.
func (m *Feedback) MarshalJSON() ([]byte, error) {
	type plain Feedback
	p := plain(*m)
	if p.Reports == nil {
		p.Reports = []FeedbackReport{}
	}
	return json.Marshal(p)
}
