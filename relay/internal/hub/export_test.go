package hub

// SetBeforeRegister makes f run between a connection's authentication and its registration.
func (h *Hub) SetBeforeRegister(f func()) { h.beforeRegister = f }
