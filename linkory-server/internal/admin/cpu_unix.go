//go:build !windows

package admin

import (
	"syscall"
	"time"
)

// processCPUTime is user+system CPU time consumed by this process so far.
func processCPUTime() time.Duration {
	var ru syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &ru) != nil {
		return 0
	}
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}
