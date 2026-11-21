package account

import (
	"context"
	"time"

	"github.com/tonimelisma/latchkey/relay/internal/limit"
	"github.com/tonimelisma/latchkey/relay/internal/store"
)

// Security emails (FR-696 to FR-699a, plan D5).
//
// Each account gets alertBurst at once, then one more every alertRefill: enough for setting up
// several machines and Claude apps in one sitting, and few enough that a flood can't bury the
// Owner's inbox. The whole relay sends at most alertSendBurst at once, then one every
// alertSendRefill, kept apart from the sign-in codes' allowance so a flood of sign-up codes
// can't silence them.
//
// Other accounts must not be able to silence an Owner's email either (security review,
// 2026-11-21). So each account also holds a reserve of alertReserve, one back every
// alertReserveRefill (3 in any 6 hours). A reserve-covered email is paid from a relay-wide
// allowance of its own, alertReserveSendBurst at once, then one every alertReserveSendRefill,
// which ordinary emails never touch, so a flood of them can't drain it; all accounts' reserves
// together stay bounded by it. Past it, a reserve-covered email falls back to the ordinary
// allowance; past both, it isn't sent.
//
// alertSlots are sent at once, alertReservedSlots of them kept for reserve-covered emails, so
// other accounts' ordinary emails can't hold every slot. One that finds its slots busy waits up
// to alertSlotWait for one, then gets alertSendTimeout to send; at most maxAlertWaiting of each
// kind wait, and one more is dropped.
const (
	alertBurst             = 10
	alertRefill            = 6 * time.Minute
	alertReserve           = 3
	alertReserveRefill     = 2 * time.Hour
	alertSendBurst         = 100
	alertSendRefill        = 30 * time.Second
	alertReserveSendBurst  = 300
	alertReserveSendRefill = 10 * time.Second
	alertSlots             = 16
	alertReservedSlots     = 4
)

// Variables so tests can change them.
var (
	alertSlotWait    = 30 * time.Second
	alertSendTimeout = backgroundSendTimeout
	maxAlertWaiting  = 256
)

// Stable log messages, for an operator's alarm.
const (
	logAlertRelayLimit   = "security email not sent: relay-wide limit reached"
	logAlertReserveLimit = "security email not sent: relay-wide limit for reserved emails reached"
	logAlertTooMany      = "security email not sent: too many waiting to be sent"
	logAlertNoSlot       = "security email not sent: no sending slot in time"
)

// alert emails the account's Owner about a change to its security, in the background, after the
// change is made: the request that made it never waits for the mail server and never fails
// because of it. A send that is over a limit or that fails is logged, without the address.
func (s *Service) alert(ctx context.Context, userID string, a alertEmail) {
	if s.cfg.Mailer == nil {
		return // no email server: nothing is emailed (spec 009)
	}
	reserved, ok := s.allowAlert(userID, a.what)
	if !ok {
		return
	}
	base := context.WithoutCancel(ctx)
	s.background.Go(func() {
		defer s.alertDone(reserved)
		slot := s.alertSlot(base, reserved)
		if slot == nil {
			s.cfg.Logger.Error(logAlertNoSlot, "change", a.what, "user", userID)
			return
		}
		defer func() { <-slot }()
		ctx, cancel := context.WithTimeout(base, alertSendTimeout) // from now: the slot is held
		defer cancel()
		u, err := s.cfg.Store.User(ctx, userID)
		if err == nil {
			err = s.cfg.Mailer.Send(ctx, u.Email, a.subject, a.body)
		}
		if err != nil {
			s.cfg.Logger.Error("security email not sent", "change", a.what, "user", userID, "err", err)
		}
	})
}

// alertSlot takes a sending slot, waiting up to alertSlotWait, and returns the channel to give
// it back to, or nil when none came free. A reserve-covered email may take any slot.
func (s *Service) alertSlot(ctx context.Context, reserved bool) chan struct{} {
	ctx, cancel := context.WithTimeout(ctx, alertSlotWait)
	defer cancel()
	reservedSlots := s.alertReservedSlots
	if !reserved {
		reservedSlots = nil // a nil channel is never ready
	}
	select {
	case reservedSlots <- struct{}{}:
		return s.alertReservedSlots
	case s.alertSlots <- struct{}{}:
		return s.alertSlots
	case <-ctx.Done():
		return nil
	}
}

// alertDone counts an email that was accepted as no longer waiting or sending.
func (s *Service) alertDone(reserved bool) {
	s.alertMu.Lock()
	s.alertPending[kindIndex(reserved)]--
	s.alertMu.Unlock()
}

func kindIndex(reserved bool) int {
	if reserved {
		return 1
	}
	return 0
}

// allowAlert decides whether the account's email may go out, and whether its reserve covers it.
// It spends what the email needs only once every check passed: a refusal costs the account none
// of its allowance or reserve.
func (s *Service) allowAlert(userID, what string) (reserved, ok bool) {
	s.alertMu.Lock()
	defer s.alertMu.Unlock()
	now := s.now()
	if !s.alertsPerAccount.HasAt(userID, now) {
		s.cfg.Logger.Warn("security email not sent: too many for the account", "change", what, "user", userID)
		return false, false
	}
	reserved = s.alertReserves.HasAt(userID, now)
	slots := alertSlots - alertReservedSlots
	if reserved {
		slots = alertSlots
	}
	if s.alertPending[kindIndex(reserved)] >= slots+maxAlertWaiting {
		s.cfg.Logger.Error(logAlertTooMany, "change", what, "user", userID, "reserved", reserved)
		return false, false
	}
	// The refusals below are not the account's doing alone: the whole relay is sending too many,
	// which an operator should know at once.
	switch {
	case reserved:
		if !s.alertReserveSends.AllowAt("", now) && !s.alertSends.AllowAt("", now) {
			s.cfg.Logger.Error(logAlertReserveLimit, "change", what, "user", userID)
			return false, false
		}
		s.alertReserves.AllowAt(userID, now)
	case !s.alertSends.AllowAt("", now):
		s.cfg.Logger.Error(logAlertRelayLimit, "change", what, "user", userID)
		return false, false
	}
	s.alertsPerAccount.AllowAt(userID, now)
	s.alertPending[kindIndex(reserved)]++
	return reserved, true
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
