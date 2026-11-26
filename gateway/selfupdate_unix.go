//go:build !windows

package main

import (
	"os"
	"syscall"
	"time"
)

// restartSelf runs the new program in place of this one (the same process,
// so systemd, procd and a terminal all keep it); exits for the service
// manager to restart it if that fails.
func restartSelf(exe string) {
	time.Sleep(500 * time.Millisecond)
	syscall.Exec(exe, append([]string{exe}, os.Args[1:]...), os.Environ())
	restartForUpdate()
}
