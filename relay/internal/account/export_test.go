package account

import "testing"

// WaitForMail waits until every email being sent in the background has been handed to the
// mailer (or has failed).
func (s *Service) WaitForMail() { s.background.Wait() }

// PendingCeremonies is how many passkey exchanges are held in memory.
func (s *Service) PendingCeremonies() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.ceremonies)
}

// SetPendingCap lowers the cap on pending passkey exchanges and tickets for one test.
func SetPendingCap(t *testing.T, n int) {
	t.Helper()
	old := maxPending
	maxPending = n
	t.Cleanup(func() { maxPending = old })
}
