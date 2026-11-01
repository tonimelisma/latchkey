//go:build !linux

package shell

import (
	"errors"
	"os"
	"syscall"
)

// Groups exist only on Linux; elsewhere (a developer's Mac running the tests) commands run without
// them and answers say leftovers may not be stopped.
type Groups struct{}

// OpenGroups always fails outside Linux.
func OpenGroups() (*Groups, error) { return nil, errors.New("control groups exist only on Linux") }

func (*Groups) New(string) (string, *os.File, error) { return "", nil, errors.New("no control groups") }
func (*Groups) Count(string) int                     { return 0 }
func (*Groups) Kill(string) (int, error)             { return 0, nil }
func (*Groups) Leftovers() []string                  { return nil }

func procAttr(*os.File) *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setsid: true, Setctty: true}
}
