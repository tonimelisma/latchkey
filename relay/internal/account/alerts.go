package account

import (
	"context"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Security emails (FR-696 to FR-699, plan D5). Each account gets alertBurst at once, then one
// more every alertRefill: enough for setting up several machines and Claude apps in one sitting,
// and few enough that a flood can't bury the Owner's inbox. The whole relay sends at most
// alertSendBurst at once, then one every alertSendRefill, kept apart from the sign-in codes'
// allowance so a flood of sign-up codes can't silence them. At most maxAlertSends are sent at
// once, each given backgroundSendTimeout.
const (
	alertBurst      = 10
	alertRefill     = 6 * time.Minute
	alertSendBurst  = 100
	alertSendRefill = 30 * time.Second
	maxAlertSends   = 16
)

// alert emails the account's Owner about a change to its security, in the background, after the
// change is made: the request that made it never waits for the mail server and never fails
// because of it. A send that is over a limit or that fails is logged, without the address.
func (s *Service) alert(ctx context.Context, userID string, a alertEmail) {
	if s.cfg.Mailer == nil {
		return // no email server: nothing is emailed (spec 009)
	}
	now := s.now()
	if !s.alertsPerAccount.AllowAt(userID, now) {
		s.cfg.Logger.Warn("security email not sent: too many for the account", "change", a.what, "user", userID)
		return
	}
	if !s.alertSends.AllowAt("", now) {
		s.cfg.Logger.Warn("security email not sent: too many from the relay", "change", a.what, "user", userID)
		return
	}
	select {
	case s.alerting <- struct{}{}:
	default:
		s.cfg.Logger.Warn("security email not sent: too many emails in progress", "change", a.what, "user", userID)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), backgroundSendTimeout)
	s.background.Go(func() {
		defer cancel()
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
