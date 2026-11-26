package main

// The admin web portal shared by the update server and the gateway's web
// page: one account ("admin"), a one-time password after a new install or
// a reset that must be changed before anything else, sign-out after 30
// minutes without activity, a lock after 5 wrong passwords, and an API
// only the page itself can call (X-Gundil header, strict CSP).

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/scrypt"
)

const (
	sessionIdle  = 30 * time.Minute
	maxFailures  = 5
	lockDuration = 5 * time.Minute
	minPassword  = 10
)

type adminAccount struct {
	Hash       string    `json:"hash"`
	Salt       string    `json:"salt"`
	N          int       `json:"n"`
	MustChange bool      `json:"mustChange"`
	Changed    time.Time `json:"changed"`
}

// accountStore keeps the admin account; path() names files next to it
// (initial-password.txt).
type accountStore interface {
	adminAccount() *adminAccount
	setAdmin(a *adminAccount) error
	path(name string) string
}

func hashPassword(pw, salt string, n int) string {
	k, err := scrypt.Key([]byte(pw), []byte(salt), n, 8, 1, 32)
	if err != nil {
		panic(err)
	}
	return hex.EncodeToString(k)
}

// ensureAdmin makes the admin account with a one-time password when there
// is none (new install, or after a reset).
func ensureAdmin(st accountStore, n int) (string, error) {
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

// ---------------------------------------------------------------- portal

type session struct {
	last time.Time
}

// portal: sign-in, sessions and the password; the page's own API is added
// by the program that uses it.
type portal struct {
	st      accountStore
	scryptN int
	// cookie: the session cookie's name. Browsers keep cookies per host,
	// not per port, so the update server and the gateway on one machine
	// need different names, or signing in on one signs out the other.
	cookie string

	mu       sync.Mutex
	sessions map[string]*session
	failures int
	lockedTo time.Time
}

func newPortal(st accountStore, scryptN int, cookie string) *portal {
	return &portal{st: st, scryptN: scryptN, cookie: cookie, sessions: map[string]*session{}}
}

func (p *portal) checkPassword(pw string) bool {
	a := p.st.adminAccount()
	if a == nil {
		return false
	}
	got := hashPassword(pw, a.Salt, a.N)
	return subtle.ConstantTimeCompare([]byte(got), []byte(a.Hash)) == 1
}

func (p *portal) sessionOf(r *http.Request) (string, *session) {
	c, err := r.Cookie(p.cookie)
	if err != nil {
		return "", nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	s := p.sessions[c.Value]
	if s == nil {
		return "", nil
	}
	if time.Since(s.last) > sessionIdle {
		delete(p.sessions, c.Value)
		return "", nil
	}
	// Background polling (status refresh) doesn't count as activity.
	if r.Header.Get("X-Background") == "" {
		s.last = time.Now()
	}
	return c.Value, s
}

func (p *portal) newSession(rw http.ResponseWriter) {
	tok := randomToken()
	p.mu.Lock()
	for k, s := range p.sessions {
		if time.Since(s.last) > sessionIdle {
			delete(p.sessions, k)
		}
	}
	p.sessions[tok] = &session{last: time.Now()}
	p.mu.Unlock()
	http.SetCookie(rw, &http.Cookie{Name: p.cookie, Value: tok, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode})
}

func (p *portal) endSessions(except string) {
	p.mu.Lock()
	for k := range p.sessions {
		if k != except {
			delete(p.sessions, k)
		}
	}
	p.mu.Unlock()
}

// routes adds the sign-in API to [m].
func (p *portal) routes(m *http.ServeMux) {
	m.HandleFunc("GET /api/session", p.apiSession)
	m.HandleFunc("POST /api/login", p.apiLogin)
	m.HandleFunc("POST /api/logout", p.apiLogout)
	m.HandleFunc("POST /api/password", p.auth(true, p.apiPassword))
}

// auth: signed in, and (unless [duringChange]) the one-time password has
// been changed.
func (p *portal) auth(duringChange bool, h http.HandlerFunc) http.HandlerFunc {
	return func(rw http.ResponseWriter, r *http.Request) {
		_, s := p.sessionOf(r)
		if s == nil {
			fail(rw, http.StatusUnauthorized, "signed out")
			return
		}
		if !duringChange {
			if a := p.st.adminAccount(); a == nil || a.MustChange {
				writeJSONResp(rw, http.StatusForbidden, map[string]any{"error": "change the password first", "mustChange": true})
				return
			}
		}
		h(rw, r)
	}
}

func (p *portal) apiSession(rw http.ResponseWriter, r *http.Request) {
	_, s := p.sessionOf(r)
	a := p.st.adminAccount()
	out := map[string]any{"signedIn": s != nil, "user": "admin", "idleMinutes": int(sessionIdle.Minutes())}
	if s != nil {
		out["mustChange"] = a == nil || a.MustChange
		p.mu.Lock()
		out["idleLeft"] = int((sessionIdle - time.Since(s.last)).Seconds())
		p.mu.Unlock()
	}
	writeJSONResp(rw, 200, out)
}

func (p *portal) apiLogin(rw http.ResponseWriter, r *http.Request) {
	var m struct{ User, Password string }
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	p.mu.Lock()
	if time.Now().Before(p.lockedTo) {
		left := time.Until(p.lockedTo).Round(time.Second)
		p.mu.Unlock()
		fail(rw, http.StatusTooManyRequests, fmt.Sprintf("Too many wrong passwords. Try again in %v.", left))
		return
	}
	p.mu.Unlock()
	ok := (m.User == "" || m.User == "admin") && p.checkPassword(m.Password)
	p.mu.Lock()
	if !ok {
		p.failures++
		if p.failures >= maxFailures {
			p.failures = 0
			p.lockedTo = time.Now().Add(lockDuration)
			log.Printf("web: %d wrong passwords (last from %s): sign-in locked for 5 minutes", maxFailures, clientIP(r))
		}
		p.mu.Unlock()
		time.Sleep(500 * time.Millisecond)
		fail(rw, http.StatusUnauthorized, "Wrong user name or password.")
		return
	}
	p.failures = 0
	p.mu.Unlock()
	p.newSession(rw)
	a := p.st.adminAccount()
	log.Printf("web: admin signed in from %s", clientIP(r))
	writeJSONResp(rw, 200, map[string]any{"ok": true, "mustChange": a.MustChange})
}

func (p *portal) apiLogout(rw http.ResponseWriter, r *http.Request) {
	if tok, _ := p.sessionOf(r); tok != "" {
		p.mu.Lock()
		delete(p.sessions, tok)
		p.mu.Unlock()
	}
	http.SetCookie(rw, &http.Cookie{Name: p.cookie, Value: "", Path: "/", MaxAge: -1, HttpOnly: true,
		SameSite: http.SameSiteStrictMode})
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (p *portal) apiPassword(rw http.ResponseWriter, r *http.Request) {
	var m struct{ Current, New string }
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	if !p.checkPassword(m.Current) {
		fail(rw, 400, "The current password is wrong.")
		return
	}
	if err := passwordProblem(m.New, m.Current); err != nil {
		fail(rw, 400, err.Error())
		return
	}
	salt := randomHex(16)
	if err := p.st.setAdmin(&adminAccount{Hash: hashPassword(m.New, salt, p.scryptN), Salt: salt, N: p.scryptN,
		Changed: time.Now()}); err != nil {
		fail(rw, 500, err.Error())
		return
	}
	os.Remove(p.st.path("initial-password.txt"))
	tok, _ := p.sessionOf(r)
	p.endSessions(tok) // Other signed-in browsers must sign in again.
	log.Printf("web: admin password changed")
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

// ---------------------------------------------------------------- helpers

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

func clientIP(r *http.Request) string {
	h := r.RemoteAddr
	if i := strings.LastIndex(h, ":"); i > 0 {
		h = h[:i]
	}
	return h
}

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

// writeJSON writes atomically, readable by the owner only.
func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

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
