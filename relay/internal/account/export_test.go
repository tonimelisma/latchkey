package account

import (
	"testing"
	"time"
)

// WaitForMail waits until every email being sent in the background has been handed to the
// mailer (or has failed).
func (s *Service) WaitForMail() { s.background.Wait() }

// PendingCeremonies is how many passkey exchanges are held in memory.
func (s *Service) PendingCeremonies() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.ceremonies)
}

// SetAlertTimes shortens, for one test, how long a security email waits for a sending slot and
// how long its send may take once it holds one.
func SetAlertTimes(t *testing.T, wait, send time.Duration) {
	t.Helper()
	oldWait, oldSend := alertSlotWait, alertSendTimeout
	alertSlotWait, alertSendTimeout = wait, send
	t.Cleanup(func() { alertSlotWait, alertSendTimeout = oldWait, oldSend })
}

// SetAlertWaiters lowers, for one test, how many security emails of each kind may wait for a
// sending slot.
func SetAlertWaiters(t *testing.T, n int) {
	t.Helper()
	old := maxAlertWaiting
	maxAlertWaiting = n
	t.Cleanup(func() { maxAlertWaiting = old })
}

// SetPendingCap lowers the cap on pending passkey exchanges and tickets for one test.
func SetPendingCap(t *testing.T, n int) {
	t.Helper()
	old := maxPending
	maxPending = n
	t.Cleanup(func() { maxPending = old })
}
