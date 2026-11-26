//go:build updateserver

package main

// Moving the update server to another machine with the same server code:
// the code is the public half of the server key, and the apps only trust
// the server that holds the private half. So the key moves, as a secret
// text (GUNDIL-SERVER-KEY-…): Server tab → Export / Import server key, or
// the export-key / import-key commands.

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const serverKeyPrefix = "GUNDIL-SERVER-KEY-"

// serverKeyText: the server key (and its Nostr key) as one text with a
// checksum. Whoever has it can act as this server: keep it secret.
func serverKeyText(k serverKeys) string {
	a, _ := hex.DecodeString(k.ServerKey)
	b, _ := hex.DecodeString(k.NostrKey)
	raw := append(append([]byte{}, a...), b...)
	sum := sha256.Sum256(raw)
	return serverKeyPrefix + base64.RawURLEncoding.EncodeToString(append(raw, sum[:3]...))
}

func parseServerKeyText(s string) (serverKeys, error) {
	s = strings.Join(strings.Fields(s), "") // Line breaks from copying.
	if !strings.HasPrefix(strings.ToUpper(s), serverKeyPrefix) {
		if strings.HasPrefix(strings.ToUpper(s), updateCodePrefix) {
			return serverKeys{}, errors.New("that is the server code (public); import the server KEY from Export server key on the old server (GUNDIL-SERVER-KEY-…)")
		}
		return serverKeys{}, errors.New("not a server key (it starts with GUNDIL-SERVER-KEY-)")
	}
	b, err := base64.RawURLEncoding.DecodeString(s[len(serverKeyPrefix):])
	if err != nil || len(b) != 67 {
		return serverKeys{}, errors.New("the server key is incomplete")
	}
	sum := sha256.Sum256(b[:64])
	if sum[0] != b[64] || sum[1] != b[65] || sum[2] != b[66] {
		return serverKeys{}, errors.New("the server key has a typo")
	}
	return serverKeys{ServerKey: hex.EncodeToString(b[:32]), NostrKey: hex.EncodeToString(b[32:64])}, nil
}

// codeOfKeys: the server code that goes with these keys.
func codeOfKeys(k serverKeys) string {
	b, _ := hex.DecodeString(k.ServerKey)
	return updateCodeText(keyPairFrom(b).pub)
}

// setKeys replaces keys.json (the old one is kept as keys.json.old-<time>);
// the server uses the new key after a restart.
func (s *store) setKeys(k serverKeys) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if old, err := os.ReadFile(s.path("keys.json")); err == nil {
		bak := s.path("keys.json.old-" + time.Now().Format("20060102-150405"))
		if err := os.WriteFile(bak, old, 0o600); err != nil {
			return err
		}
	}
	if err := writeJSON(s.path("keys.json"), k); err != nil {
		return err
	}
	s.keys = k
	return nil
}

// ----------------------------------------------------------------- web

// apiKeyExport: the server key, after the admin password again.
func (w *webServer) apiKeyExport(rw http.ResponseWriter, r *http.Request) {
	var m struct{ Password string }
	if readBody(r, &m) != nil || !w.checkPassword(m.Password) {
		fail(rw, 403, "Wrong password.")
		return
	}
	log.Printf("web: server key exported from %s", clientIP(r))
	writeJSONResp(rw, 200, map[string]any{"key": serverKeyText(w.st.keys), "code": w.srv.code()})
}

// apiKeyImport: with "check" only says which server code the key has;
// otherwise saves it and restarts with it.
func (w *webServer) apiKeyImport(rw http.ResponseWriter, r *http.Request) {
	var m struct {
		Password string
		Key      string
		Check    bool
	}
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	k, err := parseServerKeyText(m.Key)
	if err != nil {
		fail(rw, 400, err.Error())
		return
	}
	code := codeOfKeys(k)
	if m.Check {
		writeJSONResp(rw, 200, map[string]any{"code": code, "same": code == w.srv.code()})
		return
	}
	if !w.checkPassword(m.Password) {
		fail(rw, 403, "Wrong password.")
		return
	}
	if code == w.srv.code() {
		writeJSONResp(rw, 200, map[string]any{"code": code, "same": true, "restart": false})
		return
	}
	if err := w.st.setKeys(k); err != nil {
		fail(rw, 500, "Could not save the key: "+err.Error())
		return
	}
	log.Printf("web: server key imported from %s; new server code %s; restarting", clientIP(r), code)
	writeJSONResp(rw, 200, map[string]any{"code": code, "same": false, "restart": true})
	go w.afterKeyImport()
}

// ----------------------------------------------------------------- CLI

func exportKeyCommand(dir string) error {
	var k serverKeys
	if err := readJSON(filepath.Join(dir, "keys.json"), &k); err != nil || len(k.ServerKey) != 64 {
		return fmt.Errorf("no server key in %s", dir)
	}
	fmt.Fprintf(os.Stderr, "Server code: %s\nServer key (secret: whoever has it can act as this server):\n", codeOfKeys(k))
	fmt.Println(serverKeyText(k))
	return nil
}

func importKeyCommand(dir, text string) error {
	if text == "" || text == "-" {
		b, err := io.ReadAll(io.LimitReader(os.Stdin, 4096))
		if err != nil {
			return err
		}
		text = string(b)
	}
	k, err := parseServerKeyText(text)
	if err != nil {
		return err
	}
	st, err := openStore(dir)
	if err != nil {
		return err
	}
	if codeOfKeys(st.keys) == codeOfKeys(k) {
		fmt.Println("This server already has that key:", codeOfKeys(k))
		return nil
	}
	if err := st.setKeys(k); err != nil {
		return err
	}
	fmt.Printf("Imported. Server code: %s\nRestart the server to use it.\n", codeOfKeys(k))
	return nil
}
