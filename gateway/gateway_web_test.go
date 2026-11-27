//go:build !updateserver

package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A config like a fresh install: the template, no password or home key,
// relays and STUN that fail at once (no network in tests).
func freshConfig(t *testing.T) (string, string) {
	dir := t.TempDir()
	p := filepath.Join(dir, "gateway.conf")
	extra := "relays = wss://127.0.0.1:1\nstun = 127.0.0.1:1\nstate = " + filepath.Join(dir, "state.json") +
		"\ntest_scrypt_n = 16\nupdates = false\n"
	if err := os.WriteFile(p, []byte(configTemplate+extra), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir, p
}

type gwTest struct {
	t   *testing.T
	w   *gatewayWeb
	ts  *httptest.Server
	c   *http.Client
	pw  string
	cfg string
}

func newGWTest(t *testing.T) *gwTest {
	dir, p := freshConfig(t)
	cfg, err := parseConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	w, err := newGatewayWeb(cfg, &logRing{})
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "web-initial-password.txt"))
	if err != nil {
		t.Fatal("no one-time password file:", err)
	}
	ts := httptest.NewServer(w.handler())
	t.Cleanup(ts.Close)
	jar, _ := cookiejar.New(nil)
	return &gwTest{t: t, w: w, ts: ts, c: &http.Client{Jar: jar}, pw: strings.TrimSpace(string(b)), cfg: p}
}

func (gt *gwTest) do(method, path string, body any) (int, map[string]any) {
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, gt.ts.URL+path, r)
	req.Header.Set("X-Gundil", "1")
	req.Header.Set("Content-Type", "application/json")
	resp, err := gt.c.Do(req)
	if err != nil {
		gt.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	b, _ := io.ReadAll(resp.Body)
	json.Unmarshal(b, &out)
	return resp.StatusCode, out
}

func (gt *gwTest) signIn() {
	if code, out := gt.do("POST", "/api/login", map[string]any{"password": gt.pw}); code != 200 || out["mustChange"] != true {
		gt.t.Fatalf("login with the one-time password: %d %v", code, out)
	}
	if code, _ := gt.do("GET", "/api/status", nil); code != 403 {
		gt.t.Fatalf("before the password change the API must refuse: %d", code)
	}
	if code, out := gt.do("POST", "/api/password", map[string]any{"current": gt.pw, "new": "gate-admin-pass"}); code != 200 {
		gt.t.Fatalf("password change: %d %v", code, out)
	}
	gt.pw = "gate-admin-pass"
}

func waitFor(t *testing.T, what string, ok func() bool) {
	for i := 0; i < 200; i++ {
		if ok() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("timed out waiting for " + what)
}

// A fresh install waits for the settings; saving a home key on the page
// starts the gateway; Restart starts a new one; the page stays signed in
// throughout and never shows the key itself.
func TestGatewayWebSetupAndRestart(t *testing.T) {
	gt := newGWTest(t)
	gt.signIn()
	go gt.w.runGateways(gt.cfg)

	waitFor(t, "waiting state", func() bool { _, _, p := gt.w.current(); return p != "" })
	code, st := gt.do("GET", "/api/status", nil)
	if code != 200 || st["running"] != false || !strings.Contains(st["problem"].(string), "home_key") {
		t.Fatalf("status before the settings: %d %v", code, st)
	}
	if code, _ := gt.do("POST", "/api/check", nil); code != 409 {
		t.Fatalf("check without a gateway: %d", code)
	}

	key := make([]byte, 32)
	key[0] = 7
	pairing := pairingText(key)
	bad := map[string]any{"authMode": "home_key", "homeKey": "GUNDIL-PAIR-nope", "name": "Garage", "updates": true}
	if code, out := gt.do("POST", "/api/settings", bad); code != 400 {
		t.Fatalf("a bad home key must be refused: %d %v", code, out)
	}
	good := map[string]any{"authMode": "home_key", "homeKey": pairing, "name": "Garage gate", "shareCameras": true,
		"relays": "wss://127.0.0.1:1", "updates": false, "checkHosts": "192.168.1.50:554"}
	if code, out := gt.do("POST", "/api/settings", good); code != 200 {
		t.Fatalf("save: %d %v", code, out)
	}
	waitFor(t, "the gateway to start", func() bool { g, _, _ := gt.w.current(); return g != nil })
	g1, cfg, _ := gt.w.current()
	if cfg.Name != "Garage gate" || !cfg.ShareCameras || cfg.HomeKey == nil || cfg.Password != "" {
		t.Fatalf("running with %+v", cfg)
	}

	// The file keeps its comments and has the new values.
	b, _ := os.ReadFile(gt.cfg)
	text := string(b)
	for _, want := range []string{"home_key = " + pairing, "name = Garage gate", "share_cameras = true",
		"check_hosts = 192.168.1.50:554", "# Name the apps show."} {
		if !strings.Contains(text, want) {
			t.Fatalf("config misses %q:\n%s", want, text)
		}
	}

	// The settings page shows a fingerprint, never the key.
	code, s := gt.do("GET", "/api/settings", nil)
	raw, _ := json.Marshal(s)
	if code != 200 || s["authMode"] != "home_key" || s["homeKeyFingerprint"] != homeFingerprint(key) ||
		strings.Contains(string(raw), pairing[len(pairPrefix):len(pairPrefix)+10]) {
		t.Fatalf("settings: %d %s", code, raw)
	}

	// Saving without a new key keeps it; switching to a password needs one.
	keep := map[string]any{"authMode": "home_key", "name": "Garage", "shareCameras": false, "updates": false}
	if code, out := gt.do("POST", "/api/settings", keep); code != 200 {
		t.Fatalf("save keeping the key: %d %v", code, out)
	}
	waitFor(t, "a new gateway", func() bool { g, c, _ := gt.w.current(); return g != nil && g != g1 && c.Name == "Garage" })
	select {
	case <-g1.done:
	default:
		t.Fatal("the old gateway was not stopped")
	}
	if _, c, _ := gt.w.current(); c.HomeKey == nil || c.ShareCameras {
		t.Fatalf("after keeping the key: %+v", c)
	}
	if code, _ := gt.do("POST", "/api/settings", map[string]any{"authMode": "password", "name": "Garage"}); code != 400 {
		t.Fatalf("switching to a password without one: %d", code)
	}
	if code, _ := gt.do("POST", "/api/settings", map[string]any{"authMode": "password", "password": "short", "name": "Garage"}); code != 400 {
		t.Fatalf("a short intercom password: %d", code)
	}

	g2, _, _ := gt.w.current()
	if code, _ := gt.do("POST", "/api/restart", nil); code != 200 {
		t.Fatal("restart")
	}
	waitFor(t, "the restart", func() bool { g, _, _ := gt.w.current(); return g != nil && g != g2 })

	// Still signed in after all the restarts.
	if code, st := gt.do("GET", "/api/status", nil); code != 200 || st["running"] != true || st["name"] != "Garage" {
		t.Fatalf("status at the end: %d %v", code, st)
	}
	g, _, _ := gt.w.current()
	g.stop()
}

func TestGatewayWebOnlyFromTheLAN(t *testing.T) {
	gt := newGWTest(t)
	h := gt.w.handler()
	for addr, want := range map[string]int{
		"203.0.113.9:5000": 403, "[2001:db8::1]:5000": 403,
		"192.168.1.20:5000": 200, "10.1.2.3:5000": 200, "127.0.0.1:5000": 200, "[fe80::1]:5000": 200,
		"100.101.102.103:5000": 200, // Tailscale / CGNAT VPN.
		"100.128.0.1:5000":     403, // Just outside 100.64.0.0/10.
	} {
		req := httptest.NewRequest("GET", "/", nil)
		req.RemoteAddr = addr
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Errorf("%s: %d, want %d", addr, rec.Code, want)
		}
	}
	// The page and the shared style are there.
	for _, p := range []string{"/", "/app.js", "/style.css"} {
		req := httptest.NewRequest("GET", p, nil)
		req.RemoteAddr = "192.168.1.20:5000"
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != 200 || rec.Body.Len() < 100 {
			t.Errorf("%s: %d (%d bytes)", p, rec.Code, rec.Body.Len())
		}
		// Never an old app.js with a new page after an update.
		if cc := rec.Header().Get("Cache-Control"); cc != "no-cache" {
			t.Errorf("%s: Cache-Control %q", p, cc)
		}
	}
}

func TestSetConfigValues(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.conf")
	os.WriteFile(p, []byte("# A comment = with an equals sign\npassword = old-password-1\n# home_key = GUNDIL-PAIR-...\nname = A\n"), 0o600)
	err := setConfigValues(p, [][2]string{{"password", ""}, {"home_key", "GUNDIL-PAIR-x"}, {"name", "B = C"}, {"relays", "wss://r"}})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	want := "# A comment = with an equals sign\npassword = \nhome_key = GUNDIL-PAIR-x\nname = B = C\nrelays = wss://r\n"
	if string(b) != want {
		t.Fatalf("got:\n%s\nwant:\n%s", b, want)
	}
	if err := setConfigValues(p, [][2]string{{"name", "x\ny"}}); err == nil {
		t.Fatal("a line break must be refused")
	}
}

func TestResetWebAdmin(t *testing.T) {
	dir, p := freshConfig(t)
	cfg, _ := parseConfig(p)
	if _, err := newGatewayWeb(cfg, &logRing{}); err != nil {
		t.Fatal(err)
	}
	if !fileExists(filepath.Join(dir, "web-admin.json")) {
		t.Fatal("no account file")
	}
	if err := resetWebAdmin(cfg); err != nil {
		t.Fatal(err)
	}
	if fileExists(filepath.Join(dir, "web-admin.json")) || fileExists(filepath.Join(dir, "web-initial-password.txt")) {
		t.Fatal("account not removed")
	}
	w, _ := newGatewayWeb(cfg, &logRing{}) // The next start makes a new one.
	if a := w.st.adminAccount(); a == nil || !a.MustChange {
		t.Fatalf("new account: %+v", a)
	}
}

func TestExtraSubnets(t *testing.T) {
	got, err := parseExtraSubnets([]string{"192.168.2.0/24", " 10.20.7.9/16 ", "172.16.8.0/23", "100.64.1.0/24", "192.168.5.9", ""})
	want := []string{"192.168.2.0/24", "10.20.0.0/16", "172.16.8.0/23", "100.64.1.0/24", "192.168.5.9/32"}
	if err != nil || strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("got %v %v", got, err)
	}
	// Never the internet, never more than a private range, IPv4 only.
	for _, bad := range []string{"8.8.8.0/24", "0.0.0.0/0", "10.0.0.0/7", "172.32.0.0/16", "192.169.0.0/16",
		"100.128.0.0/16", "fd00::/8", "camera.lan", "192.168.2.0/40"} {
		if _, err := parseExtraSubnets([]string{bad}); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
	for host, want := range map[string]bool{"10.20.3.4": true, "10.21.3.4": false, "192.168.2.200": true} {
		in := inSubnet(host, "10.20.0.0/16") || inSubnet(host, "192.168.2.0/24")
		if in != want {
			t.Errorf("%s: %v", host, in)
		}
	}
	// The gateway forwards to its own LANs and the extra ones, not to itself.
	g := &gateway{cfg: &config{ExtraSubnets: []string{"192.168.77.0/24", "10.99.0.0/16"}}}
	nets := g.sharedSubnets()
	if !strings.Contains(strings.Join(nets, ","), "192.168.77.0/24") || !strings.Contains(strings.Join(nets, ","), "10.99.0.0/16") {
		t.Fatalf("shared: %v", nets)
	}
	for host, want := range map[string]bool{"192.168.77.20": true, "10.99.200.1": true, "192.168.78.20": false,
		"8.8.8.8": false, "127.0.0.1": false, "localhost": false} {
		if got := g.mayForward(host); got != want {
			t.Errorf("mayForward(%s) = %v", host, got)
		}
	}
	_, own := localAddrs()
	for _, a := range own {
		if g.mayForward(a) {
			t.Errorf("forwards to itself (%s)", a)
		}
	}
	// A bad entry in the file is an error, not silently more access.
	_, p := freshConfig(t)
	os.WriteFile(p, []byte("home_key = "+pairingText(make([]byte, 32))+"\nextra_subnets = 1.2.3.0/24\n"), 0o600)
	if _, err := parseConfig(p); err == nil || !strings.Contains(err.Error(), "private") {
		t.Fatalf("public extra subnet in the file: %v", err)
	}
}

func TestGatewayWebExtraSubnets(t *testing.T) {
	gt := newGWTest(t)
	gt.signIn()
	base := map[string]any{"authMode": "home_key", "homeKey": pairingText(make([]byte, 32)), "name": "G", "shareCameras": true}
	base["extraSubnets"] = "203.0.113.0/24"
	if code, out := gt.do("POST", "/api/settings", base); code != 400 || !strings.Contains(out["error"].(string), "private") {
		t.Fatalf("a public network must be refused: %d %v", code, out)
	}
	base["extraSubnets"] = "192.168.2.0/24, 10.20.5.0/16"
	if code, out := gt.do("POST", "/api/settings", base); code != 200 {
		t.Fatalf("save: %d %v", code, out)
	}
	if _, s := gt.do("GET", "/api/settings", nil); s["extraSubnets"] != "192.168.2.0/24, 10.20.0.0/16" {
		t.Fatalf("settings: %v", s)
	}
	b, _ := os.ReadFile(gt.cfg)
	if !strings.Contains(string(b), "extra_subnets = 192.168.2.0/24, 10.20.0.0/16") {
		t.Fatalf("config:\n%s", b)
	}
	c, err := loadConfig(gt.cfg)
	if err != nil || len(c.ExtraSubnets) != 2 {
		t.Fatalf("reload: %+v %v", c, err)
	}
}

func TestGatewayWebUpdates(t *testing.T) {
	gt := newGWTest(t)
	gt.signIn()
	// Before the gateway runs: settings only, and no check.
	code, u := gt.do("GET", "/api/update", nil)
	if code != 200 || u["status"] != nil || u["version"] != version {
		t.Fatalf("update status while waiting: %d %v", code, u)
	}
	if code, _ := gt.do("POST", "/api/update/check", nil); code != 409 {
		t.Fatalf("check while waiting: %d", code)
	}
	go gt.w.runGateways(gt.cfg)
	waitFor(t, "waiting state", func() bool { _, _, p := gt.w.current(); return p != "" })
	installs := 0
	gt.w.afterInstall = func() { installs++ }
	save := map[string]any{"authMode": "home_key", "homeKey": pairingText(make([]byte, 32)), "name": "G", "updates": true}
	if code, out := gt.do("POST", "/api/settings", save); code != 200 {
		t.Fatalf("save: %d %v", code, out)
	}
	waitFor(t, "the gateway", func() bool { g, _, _ := gt.w.current(); return g != nil })
	// No update server in this build or the settings: the check says so.
	code, out := gt.do("POST", "/api/update/check", nil)
	if code != 502 || !strings.Contains(out["error"].(string), "no update server") {
		t.Fatalf("check without a server: %d %v", code, out)
	}
	code, u = gt.do("GET", "/api/update", nil)
	st, _ := u["status"].(map[string]any)
	if code != 200 || st == nil || !strings.Contains(st["result"].(string), "no update server") || u["lastCheckAgo"] == nil {
		t.Fatalf("status after the check: %d %v", code, u)
	}
	// Install with nothing offered: it runs, finds nothing, installs nothing.
	if code, _ := gt.do("POST", "/api/update/install", nil); code != 202 {
		t.Fatalf("install: %d", code)
	}
	time.Sleep(300 * time.Millisecond)
	if installs != 0 {
		t.Fatal("installed without an update server")
	}
	g, _, _ := gt.w.current()
	g.stop()
}

// web_allow opens the page to more networks (a VPN's), at once after Save;
// too wide a network is refused.
func TestGatewayWebAllow(t *testing.T) {
	gt := newGWTest(t)
	gt.signIn()
	go gt.w.runGateways(gt.cfg) // Applies saved settings, as in the program.
	h := gt.w.handler()
	from := func(addr string) int {
		req := httptest.NewRequest("GET", "/", nil)
		req.RemoteAddr = addr
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}
	if c := from("203.0.113.9:5000"); c != 403 {
		t.Fatalf("before web_allow: %d", c)
	}
	settings := map[string]any{"authMode": "home_key", "homeKey": pairingText(make([]byte, 32)), "name": "Gate",
		"webAllow": "203.0.113.0/24, 2001:db8::/32"}
	if code, out := gt.do("POST", "/api/settings", settings); code != 200 {
		t.Fatalf("save: %d %v", code, out)
	}
	b, _ := os.ReadFile(gt.cfg)
	if !strings.Contains(string(b), "web_allow = 203.0.113.0/24, 2001:db8::/32") {
		t.Fatalf("not saved:\n%s", b)
	}
	waitFor(t, "the new settings", func() bool { return from("203.0.113.9:5000") == 200 })
	if c := from("[2001:db8::5]:5000"); c != 200 {
		t.Errorf("IPv6 in web_allow: %d", c)
	}
	if c := from("198.51.100.1:5000"); c != 403 {
		t.Errorf("not in web_allow: %d", c)
	}
	_, out := gt.do("GET", "/api/settings", nil)
	if out["webAllow"] != "203.0.113.0/24, 2001:db8::/32" {
		t.Errorf("settings show %v", out["webAllow"])
	}
	for _, bad := range []string{"0.0.0.0/0", "8.0.0.0/7", "::/0", "2000::/3", "not-a-network"} {
		settings["webAllow"] = bad
		if code, _ := gt.do("POST", "/api/settings", settings); code != 400 {
			t.Errorf("web_allow %q accepted: %d", bad, code)
		}
	}
	if got, err := parseWebAllow([]string{" 10.8.0.7 ", "fd00::1", "10.8.0.0/24"}); err != nil ||
		strings.Join(got, ",") != "10.8.0.7/32,fd00::1/128,10.8.0.0/24" {
		t.Errorf("parseWebAllow: %v %v", got, err)
	}
}
