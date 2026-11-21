package account

import (
	"context"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Security emails (FR-696 to FR-699, plan D5).
//
// Each account gets alertBurst at once, then one more every alertRefill: enough for setting up
// several machines and Claude apps in one sitting, and few enough that a flood can't bury the
// Owner's inbox. The whole relay sends at most alertSendBurst at once, then one every
// alertSendRefill, kept apart from the sign-in codes' allowance so a flood of sign-up codes
// can't silence them.
//
// Other accounts must not be able to silence an Owner's email either, by using up the relay-wide
// allowance with alerts of their own (security review, 2026-11-21). So each account also holds a
// reserve of alertReserve, one back every alertReserveRefill (3 in any 6 hours): an email the
// reserve covers needs only the account's own allowance; only one beyond it needs the relay-wide
// one too. A takeover's pairing or approval is reported even while the relay-wide limit is
// reached; only a flood on the account itself runs past the reserve.
//
// At most maxAlertSends are sent at once; one that finds them all busy waits for a free one
// within its backgroundSendTimeout rather than being dropped, so a burst from other accounts
// can't crowd it out.
const (
	alertBurst         = 10
	alertRefill        = 6 * time.Minute
	alertReserve       = 3
	alertReserveRefill = 2 * time.Hour
	alertSendBurst     = 100
	alertSendRefill    = 30 * time.Second
	maxAlertSends      = 16
)

// Stable log messages, for an operator's alarm.
const (
	logAlertRelayLimit = "security email not sent: relay-wide limit reached"
	logAlertNoSlot     = "security email not sent: no sending slot in time"
)

// alert emails the account's Owner about a change to its security, in the background, after the
// change is made: the request that made it never waits for the mail server and never fails
// because of it. A send that is over a limit or that fails is logged, without the address.
func (s *Service) alert(ctx context.Context, userID string, a alertEmail) {
	if s.cfg.Mailer == nil {
		return // no email server: nothing is emailed (spec 009)
	}
	if !s.allowAlert(userID, a.what) {
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), backgroundSendTimeout)
	s.background.Go(func() {
		defer cancel()
		select {
		case s.alerting <- struct{}{}:
		case <-ctx.Done():
			s.cfg.Logger.Error(logAlertNoSlot, "change", a.what, "user", userID)
			return
		}
		defer func() { <-s.alerting }()
		u, err := s.cfg.Store.User(ctx, userID)
		if err == nil {
			err = s.cfg.Mailer.Send(ctx, u.Email, a.subject, a.body)
		}
		if err != nil {
			s.cfg.Logger.Error("security email not sent", "change", a.what, "user", userID, "err", err)
		}
	})
}

// allowAlert decides whether the account's email may go out, and only then spends what it
// needs: a refusal costs the account none of its allowance or reserve.
func (s *Service) allowAlert(userID, what string) bool {
	s.alertMu.Lock()
	defer s.alertMu.Unlock()
	now := s.now()
	if !s.alertsPerAccount.HasAt(userID, now) {
		s.cfg.Logger.Warn("security email not sent: too many for the account", "change", what, "user", userID)
		return false
	}
	if !s.alertReserves.AllowAt(userID, now) && !s.alertSends.AllowAt("", now) {
		// Not the account's doing alone: the whole relay is sending too many. An operator
		// should know at once.
		s.cfg.Logger.Error(logAlertRelayLimit, "change", what, "user", userID)
		return false
	}
	s.alertsPerAccount.AllowAt(userID, now)
	return true
}

// DrainMail waits until every email being sent in the background has been sent or has failed, or
// until ctx ends. The relay calls it when it shuts down, after the last request.
func (s *Service) DrainMail(ctx context.Context) {
	done := make(chan struct{})
	go func() {
		s.background.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

// alertLinks are the pages a security email sends the Owner to: the account page, where a
// machine or an app is removed, and recovery.
func (s *Service) alertLinks() (account, recover string) {
	return s.link("/account", nil), s.link("/recover", nil)
}

// machinePaired reports a new machine on the account (FR-696).
func (s *Service) machinePaired(ctx context.Context, d store.Device) {
	account, recover := s.alertLinks()
	s.alert(ctx, d.UserID, emailMachinePaired(d.Kind, d.Name, s.now(), limit.Address(ctx), account, recover))
}
