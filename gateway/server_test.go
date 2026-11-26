//go:build updateserver

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

type webTest struct {
	t   *testing.T
	ts  *httptest.Server
	w   *webServer
	st  *store
	c   *http.Client
	pw  string
	dir string
}

func newWebTest(t *testing.T) *webTest {
	dir := t.TempDir()
	st, err := openStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &serverConfig{DataDir: dir, ScryptN: 16, Relays: []string{"wss://x.invalid"}, MaxLinks: 4}
	pw, err := ensureAdmin(st, cfg.ScryptN)
	if err != nil || pw == "" {
		t.Fatal("no one-time password", err)
	}
	srv, err := newUpdateServer(cfg, st)
	if err != nil {
		t.Fatal(err)
	}
	w := newWebServer(cfg, st, srv, &logRing{})
	ts := httptest.NewServer(w.handler())
	t.Cleanup(ts.Close)
	jar, _ := cookiejar.New(nil)
	return &webTest{t: t, ts: ts, w: w, st: st, c: &http.Client{Jar: jar}, pw: pw, dir: dir}
}

func (wt *webTest) do(method, path string, body any) (int, map[string]any) {
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, wt.ts.URL+path, r)
	req.Header.Set("X-Gundil", "1")
	req.Header.Set("Content-Type", "application/json")
	resp, err := wt.c.Do(req)
	if err != nil {
		wt.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	b, _ := io.ReadAll(resp.Body)
	json.Unmarshal(b, &out)
	return resp.StatusCode, out
}

func TestOneTimePasswordMustBeChanged(t *testing.T) {
	wt := newWebTest(t)
	if b, _ := os.ReadFile(wt.st.path("initial-password.txt")); strings.TrimSpace(string(b)) != wt.pw {
		t.Fatal("initial-password.txt missing")
	}
	if code, _ := wt.do("GET", "/api/devices", nil); code != 401 {
		t.Fatalf("signed out: got %d", code)
	}
	if code, _ := wt.do("POST", "/api/login", map[string]any{"user": "admin", "password": "wrong"}); code != 401 {
		t.Fatalf("wrong password: %d", code)
	}
	if code, _ := wt.do("POST", "/api/login", map[string]any{"user": "root", "password": wt.pw}); code != 401 {
		t.Fatalf("only admin exists: %d", code)
	}
	code, m := wt.do("POST", "/api/login", map[string]any{"user": "admin", "password": wt.pw})
	if code != 200 || m["mustChange"] != true {
		t.Fatalf("login: %d %v", code, m)
	}
	if code, m := wt.do("GET", "/api/devices", nil); code != 403 || m["mustChange"] != true {
		t.Fatalf("before the change everything is refused: %d %v", code, m)
	}
	if code, _ := wt.do("POST", "/api/password", map[string]any{"current": wt.pw, "new": "short"}); code != 400 {
		t.Fatal("short password accepted")
	}
	if code, _ := wt.do("POST", "/api/password", map[string]any{"current": wt.pw, "new": wt.pw}); code != 400 {
		t.Fatal("same password accepted")
	}
	if code, m := wt.do("POST", "/api/password", map[string]any{"current": wt.pw, "new": "a much better one"}); code != 200 {
		t.Fatalf("change: %d %v", code, m)
	}
	if fileExists(wt.st.path("initial-password.txt")) {
		t.Fatal("initial-password.txt kept after the change")
	}
	if code, _ := wt.do("GET", "/api/devices", nil); code != 200 {
		t.Fatalf("after the change: %d", code)
	}
	// The old password no longer works; the new one does.
	wt.do("POST", "/api/logout", nil)
	if code, _ := wt.do("POST", "/api/login", map[string]any{"password": wt.pw}); code != 401 {
		t.Fatal("old password still works")
	}
	if code, m := wt.do("POST", "/api/login", map[string]any{"password": "a much better one"}); code != 200 || m["mustChange"] != false {
		t.Fatalf("new password: %d %v", code, m)
	}
}

func (wt *webTest) signIn() {
	wt.do("POST", "/api/login", map[string]any{"password": wt.pw})
	if code, _ := wt.do("POST", "/api/password", map[string]any{"current": wt.pw, "new": "0123456789ab"}); code != 200 {
		wt.t.Fatal("password change failed")
	}
	wt.pw = "0123456789ab"
}

func TestSignedOutAfterInactivity(t *testing.T) {
	wt := newWebTest(t)
	wt.signIn()
	age := func(d time.Duration) {
		wt.w.mu.Lock()
		for _, s := range wt.w.sessions {
			s.last = time.Now().Add(-d)
		}
		wt.w.mu.Unlock()
	}
	age(29 * time.Minute)
	// Background polling doesn't keep the session alive...
	req, _ := http.NewRequest("GET", wt.ts.URL+"/api/status", nil)
	req.Header.Set("X-Gundil", "1")
	req.Header.Set("X-Background", "1")
	resp, _ := wt.c.Do(req)
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("29 min: %d", resp.StatusCode)
	}
	age(31 * time.Minute)
	if code, _ := wt.do("GET", "/api/devices", nil); code != 401 {
		t.Fatalf("31 min idle: still signed in (%d)", code)
	}
	// ...but activity does.
	wt.do("POST", "/api/login", map[string]any{"password": wt.pw})
	age(20 * time.Minute)
	wt.do("GET", "/api/devices", nil)
	age(0) // Reset by the request above? Simulate 20 more minutes from now:
	wt.w.mu.Lock()
	for _, s := range wt.w.sessions {
		s.last = time.Now().Add(-20 * time.Minute)
	}
	wt.w.mu.Unlock()
	if code, _ := wt.do("GET", "/api/devices", nil); code != 200 {
		t.Fatalf("active session expired: %d", code)
	}
}

func TestLockAfterWrongPasswords(t *testing.T) {
	wt := newWebTest(t)
	for i := 0; i < maxFailures; i++ {
		wt.do("POST", "/api/login", map[string]any{"password": "nope"})
	}
	if code, _ := wt.do("POST", "/api/login", map[string]any{"password": wt.pw}); code != 429 {
		t.Fatalf("not locked: %d", code)
	}
	wt.w.mu.Lock()
	wt.w.lockedTo = time.Now().Add(-time.Second)
	wt.w.mu.Unlock()
	if code, _ := wt.do("POST", "/api/login", map[string]any{"password": wt.pw}); code != 200 {
		t.Fatalf("after the lock: %d", code)
	}
}

func TestApiNeedsThePageHeader(t *testing.T) {
	wt := newWebTest(t)
	resp, err := wt.c.Post(wt.ts.URL+"/api/login", "application/json", strings.NewReader(`{"password":"x"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Fatalf("cross-site request: %d", resp.StatusCode)
	}
	resp, _ = wt.c.Get(wt.ts.URL + "/")
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(b), "Gundil Update Server") || resp.Header.Get("Content-Security-Policy") == "" {
		t.Fatal("page not served with its headers")
	}
}

func TestPolicyAndDecisions(t *testing.T) {
	wt := newWebTest(t)
	wt.signIn()
	// Two versions uploaded as files.
	for _, name := range []string{"app-Gundil_Intercom-1.9.1-android-arm64-v8a.apk",
		"Gundil_Intercom-1.9.0-android-arm64-v8a.apk", "app-gundil-gateway-1.9.1-linux-arm64.tar.gz"} {
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		fw, _ := mw.CreateFormFile("files", name)
		fw.Write([]byte("contents of " + name))
		mw.Close()
		req, _ := http.NewRequest("POST", wt.ts.URL+"/api/versions/upload", &buf)
		req.Header.Set("X-Gundil", "1")
		req.Header.Set("Content-Type", mw.FormDataContentType())
		resp, err := wt.c.Do(req)
		if err != nil || resp.StatusCode != 200 {
			t.Fatalf("upload %s: %v %v", name, err, resp.Status)
		}
		resp.Body.Close()
	}
	if code, _ := wt.do("POST", "/api/policy", map[string]any{"android": map[string]any{"target": "latest", "mode": "bogus"}}); code != 400 {
		t.Fatal("bad mode accepted")
	}
	if code, _ := wt.do("POST", "/api/policy", map[string]any{"android": map[string]any{"target": "latest", "mode": "auto"}}); code != 200 {
		t.Fatal("policy refused")
	}
	srv := wt.w.srv
	phone := wt.st.checkIn(device{ID: "phone-000001", Name: "Phone", Package: "android-arm64-v8a", Version: "1.9.0"})
	info := srv.decide(phone)
	tg, ok := info["target"].(map[string]any)
	if !ok || tg["version"] != "1.9.1" || info["mode"] != "auto" || tg["local"] != true || tg["downgrade"] != false {
		t.Fatalf("upgrade decision: %v", info)
	}
	if f := wt.st.fileFor("1.9.1", "android-arm64-v8a"); f == nil || f.Name != "Gundil_Intercom-1.9.1-android-arm64-v8a.apk" {
		t.Fatalf("file: %+v", f)
	}
	// Up to date: nothing to do.
	phone = wt.st.checkIn(device{ID: "phone-000001", Name: "Phone", Package: "android-arm64-v8a", Version: "1.9.1"})
	if _, ok := srv.decide(phone)["target"]; ok {
		t.Fatal("offered the version it runs")
	}
	// A pin downgrades this one device.
	wt.do("POST", "/api/devices/phone-000001", map[string]any{"pin": "1.9.0"})
	phone = wt.st.checkIn(device{ID: "phone-000001", Name: "Phone", Package: "android-arm64-v8a", Version: "1.9.1"})
	tg = srv.decide(phone)["target"].(map[string]any)
	if tg["version"] != "1.9.0" || tg["downgrade"] != true {
		t.Fatalf("pin: %v", tg)
	}
	// Families with no policy are off.
	gw := wt.st.checkIn(device{ID: "gateway-0001", Name: "Router", Package: "gateway-linux-arm64", Version: "1.9.0"})
	if m := srv.decide(gw); m["mode"] != "off" || m["target"] != nil {
		t.Fatalf("gateway without policy: %v", m)
	}
	// Removing a version.
	if code, _ := wt.do("DELETE", "/api/versions/1.9.0", nil); code != 200 {
		t.Fatal("delete")
	}
	if fileExists(wt.st.filePath("1.9.0", "Gundil_Intercom-1.9.0-android-arm64-v8a.apk")) {
		t.Fatal("copy kept after removal")
	}
}

func TestResetAdmin(t *testing.T) {
	wt := newWebTest(t)
	wt.signIn()
	code := updateCodeText(wt.st.serverKey().pub)
	if err := resetAdmin(wt.dir, true, false); err != nil {
		t.Fatal(err)
	}
	st, _ := openStore(wt.dir)
	if st.adminAccount() != nil {
		t.Fatal("admin kept")
	}
	if updateCodeText(st.serverKey().pub) != code {
		t.Fatal("server key changed without --new-key")
	}
	pw, _ := ensureAdmin(st, 16)
	if pw == "" || !st.adminAccount().MustChange {
		t.Fatal("no new one-time password")
	}
	resetAdmin(wt.dir, false, true)
	st, _ = openStore(wt.dir)
	if updateCodeText(st.serverKey().pub) == code {
		t.Fatal("--new-key kept the key")
	}
}

func TestServerCode(t *testing.T) {
	k := newKeyPair()
	c := updateCodeText(k.pub)
	got, err := parseUpdateCode(c)
	if err != nil || !bytes.Equal(got, k.pub) {
		t.Fatal(err)
	}
	bad := c[:20] + string(rune(c[20]^1)) + c[21:]
	if _, err := parseUpdateCode(bad); err == nil {
		t.Fatal("typo not caught")
	}
	if p, v := packageOf("server-gundil-update-server-1.9.1-linux-arm64.tar.gz"); p != "" || v != "" {
		t.Fatal("the server's own file is not an app package")
	}
	if p, v := packageOf("app-gundil-intercom-1.9.1-x86_64.AppImage"); p != "appimage-x86_64" || v != "1.9.1" {
		t.Fatal(p, v)
	}
	if compareVersions("1.10.0", "1.9.9") <= 0 || compareVersions("v1.9.1", "1.9.1") != 0 {
		t.Fatal("version order")
	}
}

// Starting a download job must not reset the job's lock while it is held
// ("fatal error: sync: unlock of unlocked mutex" in 1.9.1 and 1.9.2's first build,
// whenever a release was added with copies kept).
func TestImportJobStart(t *testing.T) {
	var j importJob
	j.set(func(j *importJob) { j.Error, j.Done = "old", 3 })
	j.start("1.9.3", 4)
	s := j.snapshot()
	if s["version"] != "1.9.3" || s["total"] != 4 || s["running"] != true || s["error"] != "" || s["done"] != 0 {
		t.Fatalf("job after start: %v", s)
	}
	j.set(func(j *importJob) { j.Done = 1 }) // The lock still works.
}

// Adding a release from GitHub with copies kept (through the web page):
// the server stays up and the copy is downloaded and checked.
func TestImportKeepCopies(t *testing.T) {
	file := []byte("pretend apk")
	sum := sha256.Sum256(file)
	var gh *httptest.Server
	gh = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/a.apk") {
			rw.Write(file)
			return
		}
		fmt.Fprintf(rw, `[{"tag_name":"v1.9.3","assets":[{"name":"app-Gundil_Intercom-1.9.3-android-arm64-v8a.apk",`+
			`"size":%d,"browser_download_url":"%s/a.apk","digest":"sha256:%s"}]}]`, len(file), gh.URL, hex.EncodeToString(sum[:]))
	}))
	defer gh.Close()
	old := githubAPI
	githubAPI = gh.URL
	defer func() { githubAPI = old }()

	wt := newWebTest(t)
	wt.signIn()
	if code, out := wt.do("POST", "/api/versions/import", map[string]any{"tag": "v1.9.3", "keep": []string{"android"}}); code != 200 {
		t.Fatalf("import: %d %v", code, out)
	}
	for i := 0; i < 100; i++ {
		if path, f := wt.st.localFile("Gundil_Intercom-1.9.3-android-arm64-v8a.apk"); f != nil {
			if b, _ := os.ReadFile(path); !bytes.Equal(b, file) {
				t.Fatal("wrong copy")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no copy kept; job: %v", wt.w.job.snapshot())
}
