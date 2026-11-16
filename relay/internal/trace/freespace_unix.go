//go:build unix

package trace

import "syscall"

// freeSpace is the space an unprivileged user can still write on the file system holding dir.
func freeSpace(dir string) (uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return uint64(st.Bavail) * uint64(st.Bsize), nil //nolint:gosec,unconvert // the field types differ between systems; never negative
}
