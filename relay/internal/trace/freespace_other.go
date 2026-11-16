//go:build !unix

package trace

import "errors"

// freeSpace isn't known on this system; the relay writes on (and logs it).
func freeSpace(string) (uint64, error) {
	return 0, errors.New("free space unknown on this system")
}
