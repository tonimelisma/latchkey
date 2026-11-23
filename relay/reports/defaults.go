package reports

import (
	_ "embed"
	"strings"
)

// DefaultIntakeURL is Latchkey's developer's intake, where every relay forwards the reports its
// users chose to share unless its operator sets another (spec 014 FR-1415, FR-1426).
const DefaultIntakeURL = "https://latchkey-feedback.melisma.net"

// developerKey is Latchkey's developer's public key (base64), made 2026-11-23. Its private half
// is never in this repository (FR-1430).
//
//go:embed developer.pub
var developerKey string

// DefaultDeveloperKey is the public key reports are sealed to unless an operator sets another.
func DefaultDeveloperKey() string { return strings.TrimSpace(developerKey) }
