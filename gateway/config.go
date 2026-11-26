//go:build !updateserver

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// config: one "key = value" file, the same on every platform (OpenWrt
// writes it from UCI).
type config struct {
	Password     string
	HomeKey      []byte // Used when Password is empty.
	Name         string
	ShareCameras bool
	Relays       []string
	Stun         []string
	StatePath    string
	CheckHosts   []string // --check: also try these host:port.
	Updates      bool     // Self-update from the update server.
	UpdateServer string   // Its code, instead of the built-in one.
	UpdateDelay  int      // Tests: seconds before the first check.
	Web          bool     // The settings web page (not on OpenWrt: LuCI).
	WebListen    string   // Its address, e.g. 0.0.0.0:8781.
	WebAllow     []string // More networks the web page answers (besides the LAN).
	Path         string   // This file.
	AnyHost      bool     // Tests only.
	ExtraSubnets []string // Private networks to forward to besides the own LANs.
	TestSubnets  []string // Tests only: subnets to announce.
	ScryptN      int      // Tests only.
}

func defaultConfigPath() string {
	if runtime.GOOS == "windows" {
		return filepath.Join(programData(), "Gundil", "gateway.conf")
	}
	return "/etc/gundil-gateway.conf"
}

func defaultStatePath() string {
	switch {
	case runtime.GOOS == "windows":
		return filepath.Join(programData(), "Gundil", "gateway-state.json")
	case fileExists("/etc/openwrt_release"):
		return "/etc/gundil-gateway/state.json" // Kept across reboots.
	default:
		return "/var/lib/gundil-gateway/state.json"
	}
}

func programData() string {
	if p := os.Getenv("ProgramData"); p != "" {
		return p
	}
	return `C:\ProgramData`
}

// isOpenWrt: OpenWrt has LuCI, so no web page of our own there.
func isOpenWrt() bool { return fileExists("/etc/openwrt_release") }

// loadConfig reads the file and requires the password or home key.
func loadConfig(path string) (*config, error) {
	c, err := parseConfig(path)
	if err != nil {
		return nil, err
	}
	if err := c.authProblem(); err != nil {
		return nil, err
	}
	return c, nil
}

// authProblem: why the gateway can't run yet (no password or home key).
func (c *config) authProblem() error {
	switch {
	case c.Password == "" && c.HomeKey == nil:
		return fmt.Errorf("set password (the intercom password, 10+ characters) or home_key (the pairing code from a paired app) in %s", c.Path)
	case c.Password != "" && len(c.Password) < 10:
		return fmt.Errorf("password must be the intercom password, at least 10 characters (in %s)", c.Path)
	}
	return nil
}

// parseConfig reads the file; the password or home key may still be
// missing (the web page then asks for them).
func parseConfig(path string) (*config, error) {
	c := &config{Relays: defaultRelays, Stun: defaultStunServers, StatePath: defaultStatePath(),
		ScryptN: defaultScryptN, Updates: true, Web: !isOpenWrt(), WebListen: "0.0.0.0:8781", Path: path}
	host, _ := os.Hostname()
	c.Name = "Gateway " + host
	f, err := os.Open(path)
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
		case "password":
			c.Password = v
		case "home_key":
			if v != "" {
				k, err := parseHomeKey(v)
				if err != nil {
					return nil, fmt.Errorf("%v (in %s)", err, path)
				}
				c.HomeKey = k
			}
		case "name":
			if v != "" {
				c.Name = v
			}
		case "share_cameras":
			c.ShareCameras = v == "1" || strings.EqualFold(v, "true") || strings.EqualFold(v, "yes")
		case "relays":
			if l := list(); len(l) > 0 {
				c.Relays = l
			}
		case "stun":
			if l := list(); len(l) > 0 {
				c.Stun = l
			}
		case "state":
			c.StatePath = v
		case "updates":
			c.Updates = !(v == "0" || strings.EqualFold(v, "false") || strings.EqualFold(v, "no"))
		case "update_server":
			if v != "" {
				if _, err := parseUpdateCode(v); err != nil {
					return nil, fmt.Errorf("update_server: %v (in %s)", err, path)
				}
			}
			c.UpdateServer = v
		case "web":
			c.Web = !(v == "0" || strings.EqualFold(v, "off") || strings.EqualFold(v, "false") || strings.EqualFold(v, "no"))
		case "web_listen":
			if v != "" {
				c.WebListen = v
			}
		case "web_allow":
			n, err := parseWebAllow(list())
			if err != nil {
				return nil, fmt.Errorf("web_allow: %v (in %s)", err, path)
			}
			c.WebAllow = n
		case "test_update_delay":
			fmt.Sscan(v, &c.UpdateDelay)
		case "check_hosts":
			c.CheckHosts = list()
		case "extra_subnets":
			n, err := parseExtraSubnets(list())
			if err != nil {
				return nil, fmt.Errorf("extra_subnets: %v (in %s)", err, path)
			}
			c.ExtraSubnets = n
		case "test_subnets":
			c.TestSubnets = list()
		case "test_any_host":
			c.AnyHost = v == "true"
		case "test_scrypt_n":
			fmt.Sscan(v, &c.ScryptN)
		}
	}
	return c, nil
}

// setConfigValues changes settings in the file and keeps everything else
// (comments, other keys): an existing "key = …" line is replaced, else a
// commented-out example ("# key = …"), else the line is added at the end.
// An empty value writes "key =" (off / not set).
func setConfigValues(path string, values [][2]string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	keyOf := func(line string) (string, bool) {
		t := strings.TrimSpace(line)
		commented := strings.HasPrefix(t, "#")
		t = strings.TrimSpace(strings.TrimPrefix(t, "#"))
		k, _, ok := strings.Cut(t, "=")
		if !ok {
			return "", false
		}
		k = strings.ReplaceAll(strings.TrimSpace(k), "-", "_")
		if strings.ContainsAny(k, " \t") {
			return "", false // A sentence in a comment, not "# key = value".
		}
		return k, commented
	}
	for _, kv := range values {
		k, v := kv[0], kv[1]
		if strings.ContainsAny(k+v, "\r\n") {
			return fmt.Errorf("%s: no line breaks", k)
		}
		line := k + " = " + v
		active, example := -1, -1
		for i, l := range lines {
			if key, commented := keyOf(l); key == k {
				if !commented && active < 0 {
					active = i
				} else if commented && example < 0 {
					example = i
				}
			}
		}
		switch {
		case active >= 0:
			lines[active] = line
		case example >= 0:
			lines[example] = line
		default:
			lines = append(lines, line)
		}
	}
	out := []byte(strings.Join(lines, "\n") + "\n")
	// Written in place: on Linux the file is in /etc, where the service may
	// write this file but not create others.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	if _, err := f.Write(out); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// state: this gateway's id and Nostr key, made on first start.
type state struct {
	DeviceID string `json:"deviceId"`
	NostrKey string `json:"nostrKey"`
}

func loadState(path string) (*state, error) {
	st := &state{}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, st)
	}
	changed := false
	if len(st.DeviceID) != 32 {
		st.DeviceID = randomHex(16)
		changed = true
	}
	if len(st.NostrKey) != 64 {
		st.NostrKey = randomHex(32)
		changed = true
	}
	if changed {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, err
		}
		b, _ := json.MarshalIndent(st, "", "  ")
		if err := os.WriteFile(path, b, 0o600); err != nil {
			return nil, err
		}
	}
	return st, nil
}

const configTemplate = `# Gundil Intercom gateway: lets the Gundil apps reach the cameras on this
# LAN over the internet (STUN + UDP hole punching, public Nostr relays).

# EITHER the intercom password, the same as in the apps (10+ characters)...
password =

# ...OR, when the apps use no password: the home key. In a paired app,
# Settings > Internet calls > Pairing > Copy pairing code, and paste it here.
# home_key = GUNDIL-PAIR-...

# Name the apps show.
name = Home gateway

# Let the apps reach devices on this LAN (cameras) through this gateway.
share_cameras = true

# Optional: other private networks it may forward to as well (cameras on
# another VLAN or a routed subnet), comma separated. This device must be
# able to reach them. Only 10.x, 172.16-31.x, 192.168.x and 100.64-127.x.
# extra_subnets = 192.168.2.0/24, 10.20.0.0/16

# The settings web page (not on OpenWrt, which has LuCI):
# http://<this device>:8781, only from the LAN (and Tailscale / CGNAT VPN
# addresses, 100.64.0.0/10). web = off turns it off.
# web = on
# web_listen = 0.0.0.0:8781
# Optional: more networks it may be opened from, e.g. your VPN's subnet
# (comma separated; a single address or a network, IPv4 or IPv6). Only
# networks you trust: the page controls the gateway, over plain HTTP.
# web_allow = 10.8.0.0/24, fd7a:115c:a1e0::/48

# Optional: other Nostr relays (comma separated).
# relays = wss://relay.damus.io, wss://nos.lol

# Self-update from the update server (when this build has its code, or
# update_server is set). The server decides the version.
# updates = true
# update_server = GUNDIL-UPDATE-...
`
