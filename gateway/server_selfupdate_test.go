//go:build updateserver

package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A release archive like build-server.sh makes: the program and web/.
func serverArchive(t *testing.T, ver, program, page string) []byte {
	var buf strings.Builder
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	top := "gundil-update-server-" + ver + "-linux-x"
	for name, body := range map[string]string{
		top + "/gundil-update-server":       program,
		top + "/web/index.html":             page,
		top + "/web/app.js":                 "js " + ver,
		top + "/install.sh":                 "#!/bin/sh",
		top + "/tools/gundil-update-server": "not this one",
	} {
		tw.WriteHeader(&tar.Header{Name: name, Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg})
		tw.Write([]byte(body))
	}
	tw.Close()
	gz.Close()
	return []byte(buf.String())
}

type selfTest struct {
	u         *selfUpdater
	exe, web  string
	restarted chan string
	body      []byte
	sums      string
}

func newSelfTest(t *testing.T, latest string) *selfTest {
	if serverAsset() == "" {
		t.Skip("no server file for this platform")
	}
	dir := t.TempDir()
	st := &selfTest{exe: filepath.Join(dir, "gundil-update-server"), web: filepath.Join(dir, "web")}
	os.WriteFile(st.exe, []byte("old program"), 0o755)
	os.MkdirAll(st.web, 0o755)
	os.WriteFile(filepath.Join(st.web, "index.html"), []byte("old page"), 0o644)
	os.WriteFile(filepath.Join(st.web, "stale.js"), []byte("gone after the update"), 0o644)
	st.body = serverArchive(t, latest, "new program", "new page")
	ts := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) { rw.Write(st.body) }))
	t.Cleanup(ts.Close)
	asset := "server-gundil-update-server-" + latest + "-" + serverAsset()
	sum := sha256.Sum256(st.body)
	st.sums = hex.EncodeToString(sum[:]) + "  " + asset + "\n"
	rels := []ghRelease{
		{Tag: "v" + latest, Assets: []ghAsset{{Name: asset, URL: ts.URL + "/" + asset}}},
		{Tag: "v0.0.1", Assets: []ghAsset{{Name: "server-gundil-update-server-0.0.1-" + serverAsset(), URL: ts.URL}}},
		{Tag: "v99.0.0", Prerelease: true, Assets: []ghAsset{{Name: "server-gundil-update-server-99.0.0-" + serverAsset(), URL: ts.URL}}},
		{Tag: "v98.0.0", Assets: []ghAsset{{Name: "app-gundil-gateway-98.0.0-linux-x86_64.tar.gz", URL: ts.URL}}},
	}
	st.u = newSelfUpdater("owner/repo", st.web)
	st.u.releases = func(string) ([]ghRelease, error) { return rels, nil }
	st.u.sums = func(ghRelease) (string, string) { return st.sums, "" }
	st.u.exe = func() (string, error) { return st.exe, nil }
	st.restarted = make(chan string, 1)
	st.u.afterInstall = func(exe string) { st.restarted <- exe }
	return st
}

func read(t *testing.T, p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return "(missing)"
	}
	return string(b)
}

func TestServerSelfUpdate(t *testing.T) {
	old := version
	version = "1.2.0"
	defer func() { version = old }()

	st := newSelfTest(t, "1.3.0")
	if err := st.u.check(); err != nil {
		t.Fatal(err)
	}
	s := st.u.status()
	if s.Latest != "1.3.0" || !s.Available || s.Busy != "" {
		t.Fatalf("check: newest stable release with a server file: %+v", s)
	}
	installed, err := st.u.install()
	if err != nil || !installed {
		t.Fatalf("install: %v %v", installed, err)
	}
	if got := read(t, st.exe); got != "new program" {
		t.Errorf("program: %q", got)
	}
	if got := read(t, filepath.Join(st.web, "index.html")); got != "new page" {
		t.Errorf("web page: %q", got)
	}
	if got := read(t, filepath.Join(st.web, "stale.js")); got != "(missing)" {
		t.Errorf("the old web folder was merged, not replaced: %q", got)
	}
	for _, p := range []string{st.exe + ".new", st.web + ".new", st.web + ".old"} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("left behind: %s", p)
		}
	}
	if s := st.u.status(); !strings.HasPrefix(s.Result, "Installed 1.3.0") {
		t.Errorf("result: %q", s.Result)
	}
}

func TestServerSelfUpdateRefusesBadFiles(t *testing.T) {
	old := version
	version = "1.2.0"
	defer func() { version = old }()

	st := newSelfTest(t, "1.3.0")
	st.sums = strings.Repeat("0", 64) + "  server-gundil-update-server-1.3.0-" + serverAsset() + "\n"
	if installed, err := st.u.install(); err == nil || installed || !strings.Contains(err.Error(), "damaged") {
		t.Fatalf("a file that isn't the release's must be refused: %v %v", installed, err)
	}
	st.sums = ""
	if _, err := st.u.install(); err == nil || !strings.Contains(err.Error(), "can't check") {
		t.Fatalf("a file without a checksum must be refused: %v", err)
	}
	if read(t, st.exe) != "old program" || read(t, filepath.Join(st.web, "index.html")) != "old page" {
		t.Fatal("refused, but something was replaced")
	}
	if s := st.u.status(); !strings.HasPrefix(s.Result, "Not installed") {
		t.Errorf("result: %q", s.Result)
	}

	// With the release key built in, an unsigned release is refused.
	keyOld := releaseKey
	releaseKey = "BGVuaWdtYS1rZXktbm90LXJlYWxseS1hLWtleS1idXQtNjUtYnl0ZXMtbG9uZy4uLi4uLi4uLi4uLg=="
	defer func() { releaseKey = keyOld }()
	sum := sha256.Sum256(st.body)
	st.sums = hex.EncodeToString(sum[:]) + "  server-gundil-update-server-1.3.0-" + serverAsset() + "\n"
	if _, err := st.u.install(); err == nil || read(t, st.exe) != "old program" {
		t.Fatalf("with a release key, an unsigned release must be refused: %v", err)
	}
}

func TestServerSelfUpdateUpToDate(t *testing.T) {
	old := version
	version = "1.3.0"
	defer func() { version = old }()
	st := newSelfTest(t, "1.3.0")
	if installed, err := st.u.install(); err != nil || installed {
		t.Fatalf("nothing newer: %v %v", installed, err)
	}
	if s := st.u.status(); s.Available || !strings.HasPrefix(s.Result, "Up to date") {
		t.Fatalf("%+v", s)
	}
	if read(t, st.exe) != "old program" {
		t.Fatal("replaced without a newer version")
	}
}

// The web API: check, then install in the background and restart.
func TestServerSelfUpdateWeb(t *testing.T) {
	old := version
	version = "1.2.0"
	defer func() { version = old }()
	wt := newWebTest(t)
	wt.signIn()
	st := newSelfTest(t, "1.3.0")
	wt.w.self = st.u
	if code, m := wt.do("POST", "/api/self-update/check", nil); code != 200 || m["latest"] != "1.3.0" || m["available"] != true {
		t.Fatalf("check: %d %v", code, m)
	}
	if code, _ := wt.do("POST", "/api/self-update/install", nil); code != 202 {
		t.Fatalf("install: %d", code)
	}
	select {
	case exe := <-st.restarted:
		if exe != st.exe || read(t, st.exe) != "new program" {
			t.Fatalf("restarted %q with %q", exe, read(t, st.exe))
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("not installed: %+v", st.u.status())
	}
}

// A test build (1.3.0-test.2) is older than its release.
func TestServerSelfUpdateFromTestBuild(t *testing.T) {
	old := version
	version = "1.3.0-test.2"
	defer func() { version = old }()
	st := newSelfTest(t, "1.3.0")
	if installed, err := st.u.install(); err != nil || !installed || read(t, st.exe) != "new program" {
		t.Fatalf("1.3.0 must replace 1.3.0-test.2: %v %v", installed, err)
	}
}
