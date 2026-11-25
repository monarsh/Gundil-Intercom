//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
	"golang.org/x/sys/windows/svc/mgr"
)

const serviceName = "GundilGateway"

type handler struct{ run func() }

func (h handler) Execute(_ []string, r <-chan svc.ChangeRequest, s chan<- svc.Status) (bool, uint32) {
	s <- svc.Status{State: svc.StartPending}
	go h.run()
	s <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for c := range r {
		switch c.Cmd {
		case svc.Interrogate:
			s <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			s <- svc.Status{State: svc.StopPending}
			return false, 0
		}
	}
	return false, 0
}

// runAsService runs under the Service Control Manager; false when started
// from a console.
func runAsService(run func()) bool {
	ok, err := svc.IsWindowsService()
	if err != nil || !ok {
		return false
	}
	if el, err := eventlog.Open(serviceName); err == nil {
		w := eventWriter{el}
		logToEventLog(w)
	}
	svc.Run(serviceName, handler{run})
	return true
}

type eventWriter struct{ el *eventlog.Log }

func (w eventWriter) Write(p []byte) (int, error) {
	w.el.Info(1, string(p))
	return len(p), nil
}

func installService(cfgPath string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.Abs(exe)
	if !fileExists(cfgPath) {
		os.MkdirAll(filepath.Dir(cfgPath), 0o700)
		if err := os.WriteFile(cfgPath, []byte(configTemplate), 0o600); err != nil {
			return err
		}
		// Only Administrators and SYSTEM may read it (it holds the password or home key).
		exec.Command("icacls", cfgPath, "/inheritance:r", "/grant:r",
			"Administrators:F", "SYSTEM:F").Run()
		fmt.Printf("Wrote %s: set the password or home_key there, then run install again.\n", cfgPath)
		return nil
	}
	if _, err := loadConfig(cfgPath); err != nil {
		return err
	}
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("run as Administrator: %v", err)
	}
	defer m.Disconnect()
	if s, err := m.OpenService(serviceName); err == nil {
		s.Close()
		return fmt.Errorf("already installed (uninstall first)")
	}
	s, err := m.CreateService(serviceName, exe, mgr.Config{
		DisplayName: "Gundil Intercom gateway",
		Description: "Lets the Gundil Intercom apps reach the cameras on this LAN over the internet.",
		StartType:   mgr.StartAutomatic,
	}, "--config="+cfgPath)
	if err != nil {
		return err
	}
	defer s.Close()
	s.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 30 * time.Second},
		{Type: mgr.ServiceRestart, Delay: time.Minute},
	}, 86400)
	eventlog.InstallAsEventCreate(serviceName, eventlog.Error|eventlog.Warning|eventlog.Info)
	exec.Command("netsh", "advfirewall", "firewall", "add", "rule",
		"name=Gundil gateway", "dir=in", "action=allow", "program="+exe, "enable=yes").Run()
	if err := s.Start(); err != nil {
		return err
	}
	fmt.Println("Installed and started the GundilGateway service.")
	return nil
}

func uninstallService() error {
	m, err := mgr.Connect()
	if err != nil {
		return fmt.Errorf("run as Administrator: %v", err)
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return fmt.Errorf("not installed")
	}
	defer s.Close()
	s.Control(svc.Stop)
	if err := s.Delete(); err != nil {
		return err
	}
	eventlog.Remove(serviceName)
	exec.Command("netsh", "advfirewall", "firewall", "delete", "rule", "name=Gundil gateway").Run()
	fmt.Println("Removed the GundilGateway service.")
	return nil
}
