package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

type memAccounts struct {
	dir string
	a   *adminAccount
}

func (m *memAccounts) adminAccount() *adminAccount    { return m.a }
func (m *memAccounts) setAdmin(a *adminAccount) error { m.a = a; return nil }
func (m *memAccounts) path(name string) string        { return filepath.Join(m.dir, name) }

// The update server and the gateway on one machine: one browser, one host,
// two ports. Browsers keep cookies per host, not per port, so each page
// needs its own cookie name; signing in on one must not sign out the other.
func TestPortalsOnOneHostKeepTheirSessions(t *testing.T) {
	jar, _ := cookiejar.New(nil) // Like a browser: ignores the port.
	c := &http.Client{Jar: jar}
	call := func(ts *httptest.Server, method, path string, body any) map[string]any {
		var b []byte
		if body != nil {
			b, _ = json.Marshal(body)
		}
		req, _ := http.NewRequest(method, ts.URL+path, bytes.NewReader(b))
		req.Header.Set("X-Gundil", "1")
		req.Header.Set("Content-Type", "application/json")
		resp, err := c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		json.NewDecoder(resp.Body).Decode(&out)
		return out
	}
	start := func(cookie string) *httptest.Server {
		st := &memAccounts{dir: t.TempDir()}
		pw, err := ensureAdmin(st, 16)
		if err != nil {
			t.Fatal(err)
		}
		m := http.NewServeMux()
		newPortal(st, 16, cookie).routes(m)
		ts := httptest.NewServer(m)
		t.Cleanup(ts.Close)
		if out := call(ts, "POST", "/api/login", map[string]any{"password": pw}); out["ok"] != true {
			t.Fatalf("%s: login: %v", cookie, out)
		}
		return ts
	}
	server := start("gundil_server_session")
	gateway := start("gundil_gateway_session")
	for name, ts := range map[string]*httptest.Server{"update server": server, "gateway": gateway} {
		if out := call(ts, "GET", "/api/session", nil); out["signedIn"] != true {
			t.Errorf("%s was signed out by signing in on the other page: %v", name, out)
		}
	}
}
