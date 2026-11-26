//go:build updateserver

package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// serverConfig: an optional "key = value" file. Everything has a default,
// so the server also runs without one.
type serverConfig struct {
	Listen    string // Web page, e.g. 0.0.0.0:8780.
	DataDir   string
	WebDir    string // Front-end files; the built-in copy when missing.
	Repo      string // GitHub repository with the releases.
	Relays    []string
	Stun      []string
	MaxLinks  int
	ScryptN   int // Admin password hash (tests use a small one).
	TestNoNet bool
}

func defaultServerConfigPath() string {
	if runtime.GOOS == "windows" {
		return filepath.Join(programData(), "Gundil", "update-server.conf")
	}
	if os.Getenv("APPIMAGE") != "" {
		return filepath.Join(userConfigDir(), "gundil-update-server", "server.conf")
	}
	return "/etc/gundil-update-server.conf"
}

func defaultDataDir() string {
	switch {
	case runtime.GOOS == "windows":
		return filepath.Join(programData(), "Gundil", "update-server")
	case os.Getenv("APPIMAGE") != "":
		return filepath.Join(userDataDir(), "gundil-update-server")
	case fileExists("/etc/openwrt_release"):
		return "/etc/gundil-update-server" // Kept across reboots (flash).
	default:
		return "/var/lib/gundil-update-server"
	}
}

func userConfigDir() string {
	if d := os.Getenv("XDG_CONFIG_HOME"); d != "" {
		return d
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config")
}

func userDataDir() string {
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return d
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".local", "share")
}

func programData() string {
	if p := os.Getenv("ProgramData"); p != "" {
		return p
	}
	return `C:\ProgramData`
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// defaultWebDir: "web" next to the program, or the installed copy.
func defaultWebDir() string {
	if exe, err := os.Executable(); err == nil {
		d := filepath.Join(filepath.Dir(exe), "web")
		if fileExists(filepath.Join(d, "index.html")) {
			return d
		}
	}
	for _, d := range []string{"/usr/share/gundil-update-server/web", "/www/gundil-update-server"} {
		if fileExists(filepath.Join(d, "index.html")) {
			return d
		}
	}
	return ""
}

func loadServerConfig(path string) (*serverConfig, error) {
	c := &serverConfig{Listen: "0.0.0.0:8780", DataDir: defaultDataDir(), WebDir: defaultWebDir(),
		Repo: "monarsh/Gundil-Intercom", Relays: defaultRelays, Stun: defaultStunServers,
		MaxLinks: 16, ScryptN: 1 << 15}
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return c, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %v", path, err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		list := func() []string {
			var out []string
			for _, x := range strings.Split(v, ",") {
				if x = strings.TrimSpace(x); x != "" {
					out = append(out, x)
				}
			}
			return out
		}
		switch strings.ReplaceAll(k, "-", "_") {
		case "listen":
			if v != "" {
				c.Listen = v
			}
		case "data_dir":
			if v != "" {
				c.DataDir = v
			}
		case "web_dir":
			c.WebDir = v
		case "github_repo":
			if v != "" {
				c.Repo = v
			}
		case "relays":
			if l := list(); len(l) > 0 {
				c.Relays = l
			}
		case "stun":
			if l := list(); len(l) > 0 {
				c.Stun = l
			}
		case "max_links":
			fmt.Sscan(v, &c.MaxLinks)
		case "test_scrypt_n":
			fmt.Sscan(v, &c.ScryptN)
		case "test_no_net":
			c.TestNoNet = v == "true"
		}
	}
	if c.MaxLinks < 1 {
		c.MaxLinks = 1
	}
	return c, nil
}

const serverConfigTemplate = `# Gundil Intercom update server. Every line is optional.

# The web page (admin only). 0.0.0.0 = every network of this device; use
# e.g. 192.168.1.1:8780 to allow only the LAN address.
listen = 0.0.0.0:8780

# Where the server keeps its key, the devices, the versions and the files.
# data_dir = /var/lib/gundil-update-server

# GitHub repository whose releases the server offers.
github_repo = monarsh/Gundil-Intercom

# Optional: other Nostr relays (comma separated).
# relays = wss://relay.damus.io, wss://nos.lol
`
