//go:build !windows

package main

import "errors"

type serviceSpec struct {
	name, display, description, firewall string
	template                             string
	needsConfig                          bool
	check                                func(path string) error
}

func runAsService(func()) bool { return false }

func installService(string) error {
	return errors.New("on Linux use install.sh (systemd), on OpenWrt the package")
}

func uninstallService() error { return installService("") }
