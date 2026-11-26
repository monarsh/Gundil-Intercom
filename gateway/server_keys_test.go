//go:build updateserver

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Moving a server: the key exported on one server, imported on another,
// gives the second one the same server code (after its restart).
func TestServerKeyMove(t *testing.T) {
	oldSrv, newSrv := newWebTest(t), newWebTest(t)
	oldSrv.signIn()
	newSrv.signIn()
	restarted := make(chan bool, 1)
	newSrv.w.afterKeyImport = func() { restarted <- true }
	oldCode := oldSrv.w.srv.code()
	if oldCode == newSrv.w.srv.code() {
		t.Fatal("two servers with one code")
	}

	if code, _ := oldSrv.do("POST", "/api/server-key/export", map[string]any{"password": "wrong-password"}); code != 403 {
		t.Fatalf("export without the right password: %d", code)
	}
	code, out := oldSrv.do("POST", "/api/server-key/export", map[string]any{"password": oldSrv.pw})
	key, _ := out["key"].(string)
	if code != 200 || !strings.HasPrefix(key, serverKeyPrefix) || out["code"] != oldCode {
		t.Fatalf("export: %d %v", code, out)
	}

	// Check (no password): which code the key gives.
	if code, out := newSrv.do("POST", "/api/server-key/import", map[string]any{"key": key, "check": true}); code != 200 || out["code"] != oldCode || out["same"] != false {
		t.Fatalf("check: %d %v", code, out)
	}
	for _, bad := range []string{oldCode, "GUNDIL-SERVER-KEY-abc", key[:len(key)-2] + "AA", "hello"} {
		if code, _ := newSrv.do("POST", "/api/server-key/import", map[string]any{"key": bad, "check": true}); code != 400 {
			t.Errorf("import of %q: %d", bad, code)
		}
	}
	if code, _ := newSrv.do("POST", "/api/server-key/import", map[string]any{"key": key, "password": "wrong-password"}); code != 403 {
		t.Fatalf("import without the right password: %d", code)
	}
	// Copied with line breaks: still fine.
	wrapped := key[:30] + "\n" + key[30:]
	code, out = newSrv.do("POST", "/api/server-key/import", map[string]any{"key": wrapped, "password": newSrv.pw})
	if code != 200 || out["restart"] != true || out["code"] != oldCode {
		t.Fatalf("import: %d %v", code, out)
	}
	<-restarted
	// After the restart (a new store and server on the same folder).
	st, err := openStore(newSrv.dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := updateCodeText(st.serverKey().pub); got != oldCode {
		t.Fatalf("after the restart the code is %s, want %s", got, oldCode)
	}
	if baks, _ := filepath.Glob(filepath.Join(newSrv.dir, "keys.json.old-*")); len(baks) != 1 {
		t.Fatalf("the old key must be kept: %v", baks)
	}
}

func TestServerKeyCommands(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	sa, _ := openStore(a)
	openStore(b)
	text := serverKeyText(sa.keys)

	// export-key prints the key; import-key KEY uses it.
	r, w, _ := os.Pipe()
	stdout := os.Stdout
	os.Stdout = w
	err := exportKeyCommand(a)
	w.Close()
	os.Stdout = stdout
	buf := make([]byte, 4096)
	n, _ := r.Read(buf)
	if err != nil || strings.TrimSpace(string(buf[:n])) != text {
		t.Fatalf("export-key: %v %q", err, buf[:n])
	}
	if err := importKeyCommand(b, text); err != nil {
		t.Fatal(err)
	}
	sb, _ := openStore(b)
	if codeOfKeys(sb.keys) != codeOfKeys(sa.keys) || sb.keys != sa.keys {
		t.Fatal("import-key didn't take the key")
	}
	if err := importKeyCommand(b, "GUNDIL-UPDATE-xyz"); err == nil || !strings.Contains(err.Error(), "server code") {
		t.Fatalf("a server code instead of the key: %v", err)
	}
}
