//go:build !windows

package main

import "errors"

func runAsService(func()) bool { return false }

func installService(string) error {
	return errors.New("on Linux use install.sh (systemd), on OpenWrt the .ipk package")
}

func uninstallService() error { return installService("") }
