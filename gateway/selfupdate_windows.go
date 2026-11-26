//go:build windows

package main

// restartSelf: the Windows service manager restarts the service when it
// ends without being stopped (recovery actions set at install).
func restartSelf(exe string) { restartForUpdate() }
