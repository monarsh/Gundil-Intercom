//go:build !updateserver

package main

// The gateway's settings web page (Linux, Raspberry Pi / Orange Pi,
// Windows; OpenWrt has LuCI instead): http://<device>:8781, only from the
// LAN. Sign-in as on the update server (webadmin.go): one "admin" account,
// a one-time password that must be changed, sign-out after 30 minutes
// without activity. Saving the settings restarts the gateway in place, so
// the page stays signed in.

import (
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

//go:embed gwweb
var gatewayWebFiles embed.FS

//go:embed web/style.css
var sharedStyle []byte

// ------------------------------------------------------------ the account

// fileAccounts: the admin account in web-admin.json next to the state file.
type fileAccounts struct {
	dir string
	mu  sync.Mutex
	a   *adminAccount
}

func openFileAccounts(dir string) *fileAccounts {
	f := &fileAccounts{dir: dir}
	var a adminAccount
	if readJSON(f.path("admin.json"), &a) == nil && a.Hash != "" {
		f.a = &a
	}
	return f
}

func (f *fileAccounts) path(name string) string { return filepath.Join(f.dir, "web-"+name) }

func (f *fileAccounts) adminAccount() *adminAccount {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.a == nil {
		return nil
	}
	a := *f.a
	return &a
}

func (f *fileAccounts) setAdmin(a *adminAccount) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := os.MkdirAll(f.dir, 0o700); err != nil {
		return err
	}
	if err := writeJSON(f.path("admin.json"), a); err != nil {
		return err
	}
	f.a = a
	return nil
}

// webDataDir: where the account is kept (next to the gateway's state).
func webDataDir(cfg *config) string { return filepath.Dir(cfg.StatePath) }

// resetWebAdmin removes the account; the gateway makes a new one with a
// one-time password when it starts.
func resetWebAdmin(cfg *config) error {
	f := &fileAccounts{dir: webDataDir(cfg)}
	removed := false
	for _, n := range []string{"admin.json", "initial-password.txt"} {
		if err := os.Remove(f.path(n)); err == nil {
			removed = true
			fmt.Println("removed", f.path(n))
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if !removed {
		fmt.Println("There was no web page account yet.")
	}
	return nil
}

// ------------------------------------------------------------ the server

type gatewayWeb struct {
	*portal
	cfgPath string
	log     *logRing
	started time.Time
	reload  chan struct{} // Restart the gateway with the saved settings.
	// afterInstall runs when an update was installed (restartForUpdate;
	// tests replace it).
	afterInstall func()

	mu      sync.Mutex
	g       *gateway // nil while the password or home key is missing.
	cfg     *config
	problem string
}

func newGatewayWeb(cfg *config, lr *logRing) (*gatewayWeb, error) {
	accounts := openFileAccounts(webDataDir(cfg))
	pw, err := ensureAdmin(accounts, cfg.ScryptN)
	if err != nil {
		return nil, fmt.Errorf("web page account: %v", err)
	}
	if pw != "" {
		log.Printf("*** Web page: new admin account. Sign in as \"admin\" with the one-time password %s", pw)
		log.Printf("*** (also in %s); you must choose a new password first.", accounts.path("initial-password.txt"))
	}
	return &gatewayWeb{portal: newPortal(accounts, cfg.ScryptN), cfgPath: cfg.Path, log: lr,
		started: time.Now(), reload: make(chan struct{}, 1), cfg: cfg, afterInstall: restartForUpdate}, nil
}

// setGateway: the gateway now running (nil: waiting for settings).
func (w *gatewayWeb) setGateway(g *gateway, cfg *config, problem string) {
	w.mu.Lock()
	w.g, w.cfg, w.problem = g, cfg, problem
	w.mu.Unlock()
}

func (w *gatewayWeb) current() (*gateway, *config, string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.g, w.cfg, w.problem
}

func (w *gatewayWeb) handler() http.Handler {
	m := http.NewServeMux()
	w.routes(m)
	m.HandleFunc("GET /api/status", w.auth(false, w.apiStatus))
	m.HandleFunc("GET /api/settings", w.auth(false, w.apiSettings))
	m.HandleFunc("POST /api/settings", w.auth(false, w.apiSettingsSet))
	m.HandleFunc("POST /api/check", w.auth(false, w.apiCheck))
	m.HandleFunc("GET /api/log", w.auth(false, w.apiLog))
	m.HandleFunc("POST /api/restart", w.auth(false, w.apiRestart))
	m.HandleFunc("GET /api/update", w.auth(false, w.apiUpdate))
	m.HandleFunc("POST /api/update/check", w.auth(false, w.apiUpdateCheck))
	m.HandleFunc("POST /api/update/install", w.auth(false, w.apiUpdateInstall))
	root, _ := fs.Sub(gatewayWebFiles, "gwweb")
	files := http.FileServer(http.FS(root))
	m.HandleFunc("GET /style.css", func(rw http.ResponseWriter, r *http.Request) {
		rw.Header().Set("Content-Type", "text/css; charset=utf-8")
		rw.Write(sharedStyle)
	})
	m.Handle("/", files)
	return lanOnly(securityHeaders(m))
}

// lanOnly: the page answers only this computer and the local networks.
func lanOnly(h http.Handler) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		ip := net.ParseIP(host)
		if err != nil || ip == nil || !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()) {
			http.Error(rw, "The gateway's web page can only be opened from the local network.", http.StatusForbidden)
			return
		}
		h.ServeHTTP(rw, r)
	})
}

// serveWeb listens in the background; the URL(s) go to the log.
func (w *gatewayWeb) serveWeb(listen string) error {
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return fmt.Errorf("web page on %s: %v", listen, err)
	}
	srv := &http.Server{Handler: w.handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil {
			log.Printf("web page stopped: %v", err)
		}
	}()
	log.Printf("Web page: %s (from the local network only)", webURLs(ln.Addr().String()))
	return nil
}

// webURLs: how to open the page, e.g. http://192.168.1.20:8781.
func webURLs(addr string) string {
	host, port, _ := net.SplitHostPort(addr)
	if ip := net.ParseIP(host); ip != nil && !ip.IsUnspecified() {
		return "http://" + net.JoinHostPort(host, port)
	}
	_, own := localAddrs()
	var urls []string
	for _, a := range own {
		urls = append(urls, "http://"+net.JoinHostPort(a, port))
	}
	if len(urls) == 0 {
		return "http://localhost:" + port
	}
	return strings.Join(urls, " or ")
}

// ---------------------------------------------------------------- the API

func (w *gatewayWeb) apiStatus(rw http.ResponseWriter, r *http.Request) {
	g, cfg, problem := w.current()
	out := map[string]any{
		"version": version, "name": cfg.Name, "running": g != nil, "problem": problem,
		"share": cfg.ShareCameras, "updates": cfg.Updates, "configPath": cfg.Path,
		"uptime": int(time.Since(w.started).Seconds()),
	}
	switch {
	case cfg.Password != "":
		out["key"] = "the intercom password"
	case cfg.HomeKey != nil:
		out["key"] = "home key " + homeFingerprint(cfg.HomeKey)
	default:
		out["key"] = ""
	}
	switch {
	case cfg.UpdateServer != "":
		out["updateServer"] = "set in the settings"
	case updateServer != "":
		out["updateServer"] = "built in"
	default:
		out["updateServer"] = ""
	}
	if g != nil {
		out["relays"], out["relaysTotal"] = g.nostr.connected(), len(cfg.Relays)
		out["public"], out["nat"] = g.lastStun()
		if cfg.ShareCameras {
			out["subnets"] = g.sharedSubnets()
		}
	}
	writeJSONResp(rw, 200, out)
}

// settingsView: what the page shows; the password and home key themselves
// never leave the gateway.
func (w *gatewayWeb) apiSettings(rw http.ResponseWriter, r *http.Request) {
	c, err := parseConfig(w.cfgPath)
	if err != nil {
		_, c, _ = w.current()
	}
	mode := ""
	switch {
	case c.Password != "":
		mode = "password"
	case c.HomeKey != nil:
		mode = "home_key"
	}
	relays := ""
	if !sameList(c.Relays, defaultRelays) {
		relays = strings.Join(c.Relays, ", ")
	}
	fp := ""
	if c.HomeKey != nil {
		fp = homeFingerprint(c.HomeKey)
	}
	writeJSONResp(rw, 200, map[string]any{
		"authMode": mode, "homeKeyFingerprint": fp, "name": c.Name, "shareCameras": c.ShareCameras,
		"relays": relays, "defaultRelays": strings.Join(defaultRelays, ", "),
		"updates": c.Updates, "updateServer": c.UpdateServer, "checkHosts": strings.Join(c.CheckHosts, ", "),
		"extraSubnets": strings.Join(c.ExtraSubnets, ", "),
	})
}

func sameList(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

type settingsChange struct {
	AuthMode     string `json:"authMode"` // "password" or "home_key"
	Password     string `json:"password"` // New; empty keeps the current one.
	HomeKey      string `json:"homeKey"`  // New; empty keeps the current one.
	Name         string `json:"name"`
	ShareCameras bool   `json:"shareCameras"`
	Relays       string `json:"relays"` // Comma separated; empty: the built-in list.
	Updates      bool   `json:"updates"`
	UpdateServer string `json:"updateServer"`
	CheckHosts   string `json:"checkHosts"`
	ExtraSubnets string `json:"extraSubnets"` // Comma separated private networks.
}

// validate turns a change into the lines to write, or says what's wrong.
func (m settingsChange) validate(cur *config) ([][2]string, error) {
	clean := func(s string) string { return strings.TrimSpace(s) }
	m.Name, m.HomeKey, m.Relays, m.UpdateServer, m.CheckHosts, m.ExtraSubnets =
		clean(m.Name), clean(m.HomeKey), clean(m.Relays), clean(m.UpdateServer), clean(m.CheckHosts), clean(m.ExtraSubnets)
	for _, v := range []string{m.Password, m.HomeKey, m.Name, m.Relays, m.UpdateServer, m.CheckHosts, m.ExtraSubnets} {
		if strings.ContainsAny(v, "\r\n") {
			return nil, errors.New("No line breaks, please.")
		}
	}
	var out [][2]string
	switch m.AuthMode {
	case "password":
		switch {
		case m.Password != "":
			if len(m.Password) < 10 {
				return nil, errors.New("The intercom password has at least 10 characters (the same as in the apps).")
			}
			if m.Password != strings.TrimSpace(m.Password) {
				return nil, errors.New("The intercom password can't start or end with a space here.")
			}
			out = append(out, [2]string{"password", m.Password})
		case cur.Password == "":
			return nil, errors.New("Enter the intercom password (the same as in the apps).")
		}
		out = append(out, [2]string{"home_key", ""})
	case "home_key":
		switch {
		case m.HomeKey != "":
			if _, err := parseHomeKey(m.HomeKey); err != nil {
				return nil, fmt.Errorf("Home key: %v", err)
			}
			out = append(out, [2]string{"home_key", m.HomeKey})
		case cur.HomeKey == nil:
			return nil, errors.New("Paste the home key (GUNDIL-PAIR-…, from a paired app: Settings → Internet calls → Pairing → Copy pairing code).")
		}
		out = append(out, [2]string{"password", ""})
	default:
		return nil, errors.New("Choose the intercom password or the home key.")
	}
	if m.Name == "" || len([]rune(m.Name)) > 64 {
		return nil, errors.New("Give the gateway a name (up to 64 characters).")
	}
	out = append(out, [2]string{"name", m.Name})
	out = append(out, [2]string{"share_cameras", fmt.Sprint(m.ShareCameras)})
	if m.Relays != "" {
		var rs []string
		for _, r := range strings.Split(m.Relays, ",") {
			if r = strings.TrimSpace(r); r == "" {
				continue
			}
			if !strings.HasPrefix(r, "wss://") && !strings.HasPrefix(r, "ws://") {
				return nil, fmt.Errorf("Relay %q: it starts with wss://", r)
			}
			rs = append(rs, r)
		}
		m.Relays = strings.Join(rs, ", ")
	}
	out = append(out, [2]string{"relays", m.Relays})
	out = append(out, [2]string{"updates", fmt.Sprint(m.Updates)})
	if m.UpdateServer != "" {
		if _, err := parseUpdateCode(m.UpdateServer); err != nil {
			return nil, fmt.Errorf("Update server: %v", err)
		}
	}
	out = append(out, [2]string{"update_server", m.UpdateServer})
	if m.CheckHosts != "" {
		var hs []string
		for _, h := range strings.Split(m.CheckHosts, ",") {
			if h = strings.TrimSpace(h); h == "" {
				continue
			}
			if _, _, err := net.SplitHostPort(h); err != nil {
				return nil, fmt.Errorf("Camera to check %q: address:port, e.g. 192.168.1.50:554", h)
			}
			hs = append(hs, h)
		}
		m.CheckHosts = strings.Join(hs, ", ")
	}
	out = append(out, [2]string{"check_hosts", m.CheckHosts})
	subnets, err := parseExtraSubnets(strings.Split(m.ExtraSubnets, ","))
	if err != nil {
		return nil, fmt.Errorf("Other networks: %v", err)
	}
	out = append(out, [2]string{"extra_subnets", strings.Join(subnets, ", ")})
	return out, nil
}

func (w *gatewayWeb) apiSettingsSet(rw http.ResponseWriter, r *http.Request) {
	var m settingsChange
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	cur, err := parseConfig(w.cfgPath)
	if err != nil {
		_, cur, _ = w.current()
	}
	values, err := m.validate(cur)
	if err != nil {
		fail(rw, 400, err.Error())
		return
	}
	if err := setConfigValues(w.cfgPath, values); err != nil {
		msg := fmt.Sprintf("Could not save %s: %v.", w.cfgPath, err)
		if runtime.GOOS == "linux" && (errors.Is(err, os.ErrPermission) || strings.Contains(err.Error(), "read-only")) {
			// Installed before the web page existed (self-update doesn't
			// change the systemd unit or the file's permissions).
			msg += " Run the gateway's install.sh again (sudo ./install.sh, or deploy-gateway.sh) so the page may save its settings."
		}
		fail(rw, 500, msg)
		return
	}
	if _, err := loadConfig(w.cfgPath); err != nil {
		fail(rw, 500, "Saved, but the settings don't work: "+err.Error())
		return
	}
	log.Printf("web: settings saved by %s; restarting the gateway", clientIP(r))
	w.restartGateway()
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *gatewayWeb) apiCheck(rw http.ResponseWriter, r *http.Request) {
	g, _, problem := w.current()
	if g == nil {
		fail(rw, 409, "The gateway isn't running: "+problem)
		return
	}
	writeJSONResp(rw, 200, g.runCheck())
}

func (w *gatewayWeb) apiLog(rw http.ResponseWriter, r *http.Request) {
	writeJSONResp(rw, 200, map[string]any{"lines": w.log.lines()})
}

func (w *gatewayWeb) apiRestart(rw http.ResponseWriter, r *http.Request) {
	log.Printf("web: restart by %s", clientIP(r))
	w.restartGateway()
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

// runGateways runs the gateway, and starts it again with the file's
// settings whenever the page asks (it stays signed in meanwhile). While the
// password or home key is missing it waits for them.
func (w *gatewayWeb) runGateways(cfgPath string) {
	for {
		cfg, err := parseConfig(cfgPath)
		if err == nil {
			err = cfg.authProblem()
		}
		if err != nil {
			log.Printf("Waiting for the settings: %v. Set them on the web page.", err)
			if cfg == nil {
				_, cfg, _ = w.current()
			}
			w.setGateway(nil, cfg, err.Error())
			<-w.reload
			continue
		}
		g, err := startGateway(cfg)
		if err != nil {
			log.Printf("gateway: %v", err)
			w.setGateway(nil, cfg, err.Error())
			select {
			case <-w.reload:
			case <-time.After(30 * time.Second):
			}
			continue
		}
		w.setGateway(g, cfg, "")
		go g.run()
		<-w.reload
		log.Printf("restarting the gateway with the new settings")
		g.stop()
	}
}

// apiUpdate: self-update's settings and the last check.
func (w *gatewayWeb) apiUpdate(rw http.ResponseWriter, r *http.Request) {
	g, cfg, _ := w.current()
	out := map[string]any{"version": version, "enabled": cfg.Updates, "package": gatewayPackage(),
		"signed": releaseKey != ""}
	switch {
	case cfg.UpdateServer != "":
		out["server"] = "set in the settings"
	case updateServer != "":
		out["server"] = "built in"
	default:
		out["server"] = ""
	}
	if g != nil {
		st := g.updateState()
		out["status"] = st
		if !st.LastCheck.IsZero() {
			out["lastCheckAgo"] = int(time.Since(st.LastCheck).Seconds())
		}
	}
	writeJSONResp(rw, 200, out)
}

// apiUpdateCheck asks the update server now (up to about half a minute).
func (w *gatewayWeb) apiUpdateCheck(rw http.ResponseWriter, r *http.Request) {
	g, _, problem := w.current()
	if g == nil {
		fail(rw, 409, "The gateway isn't running: "+problem)
		return
	}
	if _, err := g.updateNow(false); err != nil {
		fail(rw, 502, err.Error())
		return
	}
	w.apiUpdate(rw, r)
}

// apiUpdateInstall installs what the server offers, in the background; the
// gateway then restarts (the page signs in again).
func (w *gatewayWeb) apiUpdateInstall(rw http.ResponseWriter, r *http.Request) {
	g, _, problem := w.current()
	if g == nil {
		fail(rw, 409, "The gateway isn't running: "+problem)
		return
	}
	if g.updateState().Busy != "" {
		fail(rw, 409, "An update check is running; try again in a moment.")
		return
	}
	log.Printf("web: update install by %s", clientIP(r))
	go func() {
		installed, err := g.updateNow(true)
		if err != nil {
			log.Printf("self-update: %v", err)
		}
		if installed && w.afterInstall != nil {
			w.afterInstall()
		}
	}()
	writeJSONResp(rw, 202, map[string]any{"started": true})
}

// restartGateway asks runGateways to start the gateway again with the file's
// settings (the web page keeps running).
func (w *gatewayWeb) restartGateway() {
	select {
	case w.reload <- struct{}{}:
	default: // Already asked.
	}
}
