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
	AnyHost      bool     // Tests only.
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

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func loadConfig(path string) (*config, error) {
	c := &config{Relays: defaultRelays, Stun: defaultStunServers, StatePath: defaultStatePath(),
		ScryptN: defaultScryptN}
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
		case "check_hosts":
			c.CheckHosts = list()
		case "test_subnets":
			c.TestSubnets = list()
		case "test_any_host":
			c.AnyHost = v == "true"
		case "test_scrypt_n":
			fmt.Sscan(v, &c.ScryptN)
		}
	}
	switch {
	case c.Password == "" && c.HomeKey == nil:
		return nil, fmt.Errorf("set password (the intercom password, 10+ characters) or home_key (the pairing code from a paired app) in %s", path)
	case c.Password != "" && len(c.Password) < 10:
		return nil, fmt.Errorf("password must be the intercom password, at least 10 characters (in %s)", path)
	}
	return c, nil
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

# Optional: other Nostr relays (comma separated).
# relays = wss://relay.damus.io, wss://nos.lol
`
