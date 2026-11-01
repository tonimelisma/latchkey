package account

import (
	"errors"
	"net/http"
	"net/mail"
	"strings"
)

// LegalEffectiveDate is shown on the terms of service and the privacy policy. Change it whenever
// the text of either document (templates/terms.html, templates/privacy.html) changes.
const LegalEffectiveDate = "October 31, 2026"

// Operator is the person or organization running this relay, from its settings. Nothing about
// an operator is written into the software (FR-194): a self-hosted relay publishes its own
// operator's details, or none.
type Operator struct {
	Name    string // OPERATOR_NAME: who runs this relay
	Contact string // OPERATOR_CONTACT: an email address for questions, privacy requests, security and abuse reports
	// Law is OPERATOR_LAW, e.g. a state and country; the governing-law sentence appears only
	// when it is set.
	Law string
	// Providers is OPERATOR_PROVIDERS: the companies that process data for the operator, in the
	// operator's words. Without it the policy speaks of the operator's hosting and email providers.
	Providers string
	// BackupDays is BACKUP_DAYS: how long backups of the server are kept; backups are mentioned
	// only when it is set.
	BackupDays int
}

// Published reports whether the relay serves the terms and the privacy policy: both the name
// and the contact are set (FR-193).
func (o Operator) Published() bool { return o.Name != "" && o.Contact != "" }

// Validate checks the settings: name and contact together or not at all, and a contact that is
// one plain email address.
func (o Operator) Validate() error {
	var errs []error
	if (o.Name == "") != (o.Contact == "") {
		errs = append(errs, errors.New("OPERATOR_NAME and OPERATOR_CONTACT must be set together"))
	}
	if o.Contact != "" {
		if a, err := mail.ParseAddress(o.Contact); err != nil || a.Address != o.Contact || !strings.Contains(o.Contact, "@") {
			errs = append(errs, errors.New("OPERATOR_CONTACT must be one email address, without a name"))
		}
	}
	if o.BackupDays < 0 {
		errs = append(errs, errors.New("BACKUP_DAYS must be a number of days"))
	}
	return errors.Join(errs...)
}

// legalView is what the two documents are filled in with.
type legalView struct {
	Operator
	Effective string
}

// legalPage serves one of the documents, or 404 when the operator hasn't been named: a personal
// relay for oneself needs neither.
func (s *Service) legalPage(name, title string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		if !s.cfg.Operator.Published() {
			http.Error(w, "404 page not found", http.StatusNotFound)
			return
		}
		s.render(w, http.StatusOK, name, page{
			Title: title + " · Latchkey", Wide: true, Plain: true,
			Data: legalView{Operator: s.cfg.Operator, Effective: LegalEffectiveDate},
		})
	}
}

// contactSentence ends a refusal with where to ask, when the operator gave an address.
func (s *Service) contactSentence() string {
	if s.cfg.Operator.Contact == "" {
		return ""
	}
	return " To ask about it, write to " + s.cfg.Operator.Contact + "."
}
