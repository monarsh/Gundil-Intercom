//go:build updateserver

package main

// The admin web page: one account ("admin"), a one-time password after a
// new install or a reset that must be changed before anything else,
// sign-out after 30 minutes without activity, and a lock after 5 wrong
// passwords. The front end (web/) is plain HTML + JS calling /api/.

import (
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/scrypt"
	"rsc.io/qr"
)

//go:embed web
var embeddedWeb embed.FS

const (
	sessionIdle   = 30 * time.Minute
	maxFailures   = 5
	lockDuration  = 5 * time.Minute
	minPassword   = 10
	sessionCookie = "gundil_session"
	maxUpload     = 400 << 20
)

type session struct {
	last time.Time
}

type webServer struct {
	cfg *serverConfig
	st  *store
	srv *updateServer
	log *logRing
	job importJob

	mu       sync.Mutex
	sessions map[string]*session
	failures int
	lockedTo time.Time
}

func newWebServer(cfg *serverConfig, st *store, srv *updateServer, lr *logRing) *webServer {
	return &webServer{cfg: cfg, st: st, srv: srv, log: lr, sessions: map[string]*session{}}
}

// ----------------------------------------------------------- the account

func hashPassword(pw, salt string, n int) string {
	k, err := scrypt.Key([]byte(pw), []byte(salt), n, 8, 1, 32)
	if err != nil {
		panic(err)
	}
	return hex.EncodeToString(k)
}

// ensureAdmin makes the admin account with a one-time password when there
// is none (new install, or after reset-admin).
func ensureAdmin(st *store, n int) (string, error) {
	if st.adminAccount() != nil {
		return "", nil
	}
	pw := oneTimePassword()
	salt := randomHex(16)
	err := st.setAdmin(&adminAccount{Hash: hashPassword(pw, salt, n), Salt: salt, N: n,
		MustChange: true, Changed: time.Now()})
	if err != nil {
		return "", err
	}
	os.WriteFile(st.path("initial-password.txt"), []byte(pw+"\n"), 0o600)
	return pw, nil
}

func oneTimePassword() string {
	const abc = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 14)
	for i := range b {
		k, _ := rand.Int(rand.Reader, big.NewInt(int64(len(abc))))
		b[i] = abc[k.Int64()]
	}
	return string(b)
}

func (w *webServer) checkPassword(pw string) bool {
	a := w.st.adminAccount()
	if a == nil {
		return false
	}
	got := hashPassword(pw, a.Salt, a.N)
	return subtle.ConstantTimeCompare([]byte(got), []byte(a.Hash)) == 1
}

// ------------------------------------------------------------- sessions

func (w *webServer) sessionOf(r *http.Request) (string, *session) {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return "", nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	s := w.sessions[c.Value]
	if s == nil {
		return "", nil
	}
	if time.Since(s.last) > sessionIdle {
		delete(w.sessions, c.Value)
		return "", nil
	}
	// Background polling (status refresh) doesn't count as activity.
	if r.Header.Get("X-Background") == "" {
		s.last = time.Now()
	}
	return c.Value, s
}

func (w *webServer) newSession(rw http.ResponseWriter) {
	tok := randomToken()
	w.mu.Lock()
	for k, s := range w.sessions {
		if time.Since(s.last) > sessionIdle {
			delete(w.sessions, k)
		}
	}
	w.sessions[tok] = &session{last: time.Now()}
	w.mu.Unlock()
	http.SetCookie(rw, &http.Cookie{Name: sessionCookie, Value: tok, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode})
}

func (w *webServer) endSessions(except string) {
	w.mu.Lock()
	for k := range w.sessions {
		if k != except {
			delete(w.sessions, k)
		}
	}
	w.mu.Unlock()
}

// ---------------------------------------------------------------- routes

func (w *webServer) handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /api/session", w.apiSession)
	m.HandleFunc("POST /api/login", w.apiLogin)
	m.HandleFunc("POST /api/logout", w.apiLogout)
	m.HandleFunc("POST /api/password", w.auth(true, w.apiPassword))
	m.HandleFunc("GET /api/status", w.auth(false, w.apiStatus))
	m.HandleFunc("GET /api/qr.svg", w.auth(false, w.apiQR))
	m.HandleFunc("POST /api/check", w.auth(false, w.apiCheck))
	m.HandleFunc("GET /api/devices", w.auth(false, w.apiDevices))
	m.HandleFunc("POST /api/devices/{id}", w.auth(false, w.apiDeviceSet))
	m.HandleFunc("DELETE /api/devices/{id}", w.auth(false, w.apiDeviceDelete))
	m.HandleFunc("GET /api/policy", w.auth(false, w.apiPolicy))
	m.HandleFunc("POST /api/policy", w.auth(false, w.apiPolicySet))
	m.HandleFunc("GET /api/versions", w.auth(false, w.apiVersions))
	m.HandleFunc("GET /api/github", w.auth(false, w.apiGithub))
	m.HandleFunc("POST /api/versions/import", w.auth(false, w.apiImport))
	m.HandleFunc("POST /api/versions/upload", w.auth(false, w.apiUpload))
	m.HandleFunc("DELETE /api/versions/{version}", w.auth(false, w.apiVersionDelete))
	m.HandleFunc("GET /api/log", w.auth(false, w.apiLog))
	m.Handle("/", w.static())
	return securityHeaders(m)
}

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		hd := rw.Header()
		hd.Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data: blob:; style-src 'self'; script-src 'self'; frame-ancestors 'none'")
		hd.Set("X-Frame-Options", "DENY")
		hd.Set("X-Content-Type-Options", "nosniff")
		hd.Set("Referrer-Policy", "no-referrer")
		if strings.HasPrefix(r.URL.Path, "/api/") {
			hd.Set("Cache-Control", "no-store")
			// Only the page itself may call the API (a cross-site form or
			// fetch can't add this header without CORS, which is off).
			if r.Header.Get("X-Gundil") != "1" {
				http.Error(rw, "forbidden", http.StatusForbidden)
				return
			}
		}
		h.ServeHTTP(rw, r)
	})
}

func (w *webServer) static() http.Handler {
	var root fs.FS
	if w.cfg.WebDir != "" && fileExists(filepath.Join(w.cfg.WebDir, "index.html")) {
		root = os.DirFS(w.cfg.WebDir)
	} else {
		root, _ = fs.Sub(embeddedWeb, "web")
	}
	return http.FileServer(http.FS(root))
}

func writeJSONResp(rw http.ResponseWriter, code int, v any) {
	rw.Header().Set("Content-Type", "application/json")
	rw.WriteHeader(code)
	json.NewEncoder(rw).Encode(v)
}

func fail(rw http.ResponseWriter, code int, msg string) {
	writeJSONResp(rw, code, map[string]any{"error": msg})
}

func readBody(r *http.Request, v any) error {
	return json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v)
}

// auth: signed in, and (unless [duringChange]) the one-time password has
// been changed.
func (w *webServer) auth(duringChange bool, h http.HandlerFunc) http.HandlerFunc {
	return func(rw http.ResponseWriter, r *http.Request) {
		_, s := w.sessionOf(r)
		if s == nil {
			fail(rw, http.StatusUnauthorized, "signed out")
			return
		}
		if !duringChange {
			if a := w.st.adminAccount(); a == nil || a.MustChange {
				writeJSONResp(rw, http.StatusForbidden, map[string]any{"error": "change the password first", "mustChange": true})
				return
			}
		}
		h(rw, r)
	}
}

func (w *webServer) apiSession(rw http.ResponseWriter, r *http.Request) {
	_, s := w.sessionOf(r)
	a := w.st.adminAccount()
	out := map[string]any{"signedIn": s != nil, "user": "admin", "idleMinutes": int(sessionIdle.Minutes())}
	if s != nil {
		out["mustChange"] = a == nil || a.MustChange
		w.mu.Lock()
		out["idleLeft"] = int((sessionIdle - time.Since(s.last)).Seconds())
		w.mu.Unlock()
	}
	writeJSONResp(rw, 200, out)
}

func (w *webServer) apiLogin(rw http.ResponseWriter, r *http.Request) {
	var m struct{ User, Password string }
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	w.mu.Lock()
	if time.Now().Before(w.lockedTo) {
		left := time.Until(w.lockedTo).Round(time.Second)
		w.mu.Unlock()
		fail(rw, http.StatusTooManyRequests, fmt.Sprintf("Too many wrong passwords. Try again in %v.", left))
		return
	}
	w.mu.Unlock()
	ok := (m.User == "" || m.User == "admin") && w.checkPassword(m.Password)
	w.mu.Lock()
	if !ok {
		w.failures++
		if w.failures >= maxFailures {
			w.failures = 0
			w.lockedTo = time.Now().Add(lockDuration)
			log.Printf("web: %d wrong passwords (last from %s): sign-in locked for 5 minutes", maxFailures, clientIP(r))
		}
		w.mu.Unlock()
		time.Sleep(500 * time.Millisecond)
		fail(rw, http.StatusUnauthorized, "Wrong user name or password.")
		return
	}
	w.failures = 0
	w.mu.Unlock()
	w.newSession(rw)
	a := w.st.adminAccount()
	log.Printf("web: admin signed in from %s", clientIP(r))
	writeJSONResp(rw, 200, map[string]any{"ok": true, "mustChange": a.MustChange})
}

func clientIP(r *http.Request) string {
	h := r.RemoteAddr
	if i := strings.LastIndex(h, ":"); i > 0 {
		h = h[:i]
	}
	return h
}

func (w *webServer) apiLogout(rw http.ResponseWriter, r *http.Request) {
	if tok, _ := w.sessionOf(r); tok != "" {
		w.mu.Lock()
		delete(w.sessions, tok)
		w.mu.Unlock()
	}
	http.SetCookie(rw, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1, HttpOnly: true,
		SameSite: http.SameSiteStrictMode})
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiPassword(rw http.ResponseWriter, r *http.Request) {
	var m struct{ Current, New string }
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	if !w.checkPassword(m.Current) {
		fail(rw, 400, "The current password is wrong.")
		return
	}
	if err := passwordProblem(m.New, m.Current); err != nil {
		fail(rw, 400, err.Error())
		return
	}
	salt := randomHex(16)
	n := w.cfg.ScryptN
	if err := w.st.setAdmin(&adminAccount{Hash: hashPassword(m.New, salt, n), Salt: salt, N: n,
		Changed: time.Now()}); err != nil {
		fail(rw, 500, err.Error())
		return
	}
	os.Remove(w.st.path("initial-password.txt"))
	tok, _ := w.sessionOf(r)
	w.endSessions(tok) // Other signed-in browsers must sign in again.
	log.Printf("web: admin password changed")
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func passwordProblem(pw, old string) error {
	switch {
	case len([]rune(pw)) < minPassword:
		return fmt.Errorf("Use at least %d characters.", minPassword)
	case pw == old:
		return errors.New("Choose a password different from the current one.")
	case strings.EqualFold(pw, "admin") || strings.EqualFold(pw, "password") || strings.EqualFold(pw, "1234567890"):
		return errors.New("That password is too easy to guess.")
	}
	return nil
}

func (w *webServer) apiStatus(rw http.ResponseWriter, r *http.Request) {
	pub, nat := w.srv.stun(false)
	devs := w.st.deviceList()
	recent := 0
	for _, d := range devs {
		if time.Since(d.LastSeen) < 24*time.Hour {
			recent++
		}
	}
	pubText := ""
	if pub != nil {
		pubText = pub.String()
	}
	writeJSONResp(rw, 200, map[string]any{
		"version": version, "code": w.srv.code(), "relays": w.srv.nostr.connected(),
		"relaysTotal": len(w.cfg.Relays), "nat": nat, "public": pubText, "devices": len(devs),
		"recent": recent, "links": w.srv.links.Load(), "dataDir": w.cfg.DataDir,
		"repo": w.cfg.Repo, "job": w.job.snapshot(),
	})
}

func (w *webServer) apiQR(rw http.ResponseWriter, r *http.Request) {
	c, err := qr.Encode(w.srv.code(), qr.M)
	if err != nil {
		fail(rw, 500, err.Error())
		return
	}
	var b strings.Builder
	n := c.Size + 8
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges"><rect width="%d" height="%d" fill="#fff"/><path fill="#000" d="`, n, n, n, n)
	for y := 0; y < c.Size; y++ {
		for x := 0; x < c.Size; x++ {
			if c.Black(x, y) {
				fmt.Fprintf(&b, "M%d %dh1v1h-1z", x+4, y+4)
			}
		}
	}
	b.WriteString(`"/></svg>`)
	rw.Header().Set("Content-Type", "image/svg+xml")
	rw.Write([]byte(b.String()))
}

func (w *webServer) apiCheck(rw http.ResponseWriter, r *http.Request) {
	pub, nat := w.srv.stun(true)
	pubText := ""
	if pub != nil {
		pubText = pub.String()
	}
	writeJSONResp(rw, 200, map[string]any{"relays": w.srv.nostr.connected(),
		"relaysTotal": len(w.cfg.Relays), "nat": nat, "public": pubText})
}

func (w *webServer) apiDevices(rw http.ResponseWriter, r *http.Request) {
	devs := w.st.deviceList()
	out := make([]map[string]any, 0, len(devs))
	for _, d := range devs {
		out = append(out, map[string]any{"id": d.ID, "name": d.Name, "package": d.Package,
			"family": familyOf(d.Package), "version": d.Version, "os": d.OS, "address": d.Address,
			"firstSeen": d.FirstSeen, "lastSeen": d.LastSeen, "pin": d.Pin, "offered": d.Offered,
			"fetched": d.Fetched})
	}
	writeJSONResp(rw, 200, out)
}

func (w *webServer) apiDeviceSet(rw http.ResponseWriter, r *http.Request) {
	var m struct{ Pin string }
	if readBody(r, &m) != nil || (m.Pin != "" && !validVersion(m.Pin)) {
		fail(rw, 400, "bad version")
		return
	}
	if !w.st.updateDevice(r.PathValue("id"), func(d *device) { d.Pin = strings.TrimPrefix(m.Pin, "v") }) {
		fail(rw, 404, "no such device")
		return
	}
	w.st.flushDevices()
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiDeviceDelete(rw http.ResponseWriter, r *http.Request) {
	w.st.deleteDevice(r.PathValue("id"))
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiPolicy(rw http.ResponseWriter, r *http.Request) {
	writeJSONResp(rw, 200, map[string]any{"families": families, "policy": w.st.allPolicy()})
}

func (w *webServer) apiPolicySet(rw http.ResponseWriter, r *http.Request) {
	var m map[string]familyPolicy
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	for k, p := range m {
		known := false
		for _, f := range families {
			known = known || f.ID == k
		}
		if !known || (p.Mode != "off" && p.Mode != "ask" && p.Mode != "auto") ||
			(p.Target != "" && p.Target != "latest" && !validVersion(p.Target)) {
			fail(rw, 400, "bad policy for "+k)
			return
		}
		p.Target = strings.TrimPrefix(p.Target, "v")
		m[k] = p
	}
	if err := w.st.setPolicy(m); err != nil {
		fail(rw, 500, err.Error())
		return
	}
	log.Printf("web: policy changed")
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiVersions(rw http.ResponseWriter, r *http.Request) {
	writeJSONResp(rw, 200, map[string]any{"versions": w.st.versionList(), "job": w.job.snapshot()})
}

func (w *webServer) apiGithub(rw http.ResponseWriter, r *http.Request) {
	rels, err := githubReleases(w.cfg.Repo)
	if err != nil {
		fail(rw, 502, "Could not read the releases from GitHub: "+err.Error())
		return
	}
	out := []map[string]any{}
	for _, rel := range rels {
		n := 0
		for _, a := range rel.Assets {
			if p, _ := packageOf(a.Name); p != "" {
				n++
			}
		}
		out = append(out, map[string]any{"tag": rel.Tag, "name": rel.Name, "published": rel.Published,
			"prerelease": rel.Prerelease, "files": n})
	}
	writeJSONResp(rw, 200, out)
}

func (w *webServer) apiImport(rw http.ResponseWriter, r *http.Request) {
	var m struct {
		Tag  string
		Keep []string
	}
	if readBody(r, &m) != nil || !validVersion(m.Tag) {
		fail(rw, 400, "bad request")
		return
	}
	if w.job.snapshot()["running"] == true {
		fail(rw, 409, "Copies of another version are still downloading.")
		return
	}
	keep := map[string]bool{}
	for _, k := range m.Keep {
		keep[k] = true
	}
	if err := importRelease(w.st, w.cfg.Repo, m.Tag, keep, &w.job); err != nil {
		fail(rw, 502, err.Error())
		return
	}
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

// apiUpload: a release file from the admin's computer, kept on this server.
func (w *webServer) apiUpload(rw http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(rw, r.Body, maxUpload)
	mr, err := r.MultipartReader()
	if err != nil {
		fail(rw, 400, "bad upload")
		return
	}
	var added []string
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			fail(rw, 400, "upload interrupted: "+err.Error())
			return
		}
		name := filepath.Base(part.FileName())
		if name == "" || name == "." {
			continue
		}
		pkg, v := packageOf(name)
		if pkg == "" {
			fail(rw, 400, name+" is not a Gundil Intercom release file (keep its original name).")
			return
		}
		f := versionFile{Name: stripPrefix(name), Asset: name, Package: pkg, Local: true}
		dst := w.st.filePath(v, f.Name)
		os.MkdirAll(filepath.Dir(dst), 0o700)
		h := &hashCounter{}
		if err := saveChecked(dst, io.TeeReader(part, h), "", 0, nil); err != nil {
			fail(rw, 500, err.Error())
			return
		}
		f.Size, f.SHA256 = h.n, h.sum()
		// Keep the GitHub link when the same file is there already.
		if old := w.st.fileFor(v, pkg); old != nil && old.SHA256 == f.SHA256 {
			f.URL = old.URL
		}
		if err := w.st.addFiles(v, "upload", "", []versionFile{f}); err != nil {
			fail(rw, 500, err.Error())
			return
		}
		added = append(added, name)
		log.Printf("web: uploaded %s (%d KB)", name, f.Size/1024)
	}
	writeJSONResp(rw, 200, map[string]any{"ok": true, "files": added})
}

func (w *webServer) apiVersionDelete(rw http.ResponseWriter, r *http.Request) {
	if err := w.st.deleteVersion(r.PathValue("version")); err != nil {
		fail(rw, 404, err.Error())
		return
	}
	log.Printf("web: version %s removed", r.PathValue("version"))
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiLog(rw http.ResponseWriter, r *http.Request) {
	writeJSONResp(rw, 200, map[string]any{"lines": w.log.lines()})
}

// -------------------------------------------------------------- helpers

// logRing keeps the last lines of the log for the web page.
type logRing struct {
	mu  sync.Mutex
	buf []string
}

func (l *logRing) Write(p []byte) (int, error) {
	l.mu.Lock()
	for _, line := range strings.Split(strings.TrimRight(string(p), "\n"), "\n") {
		l.buf = append(l.buf, line)
	}
	if len(l.buf) > 500 {
		l.buf = l.buf[len(l.buf)-500:]
	}
	l.mu.Unlock()
	return len(p), nil
}

func (l *logRing) lines() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.buf...)
}
