//go:build !updateserver

package main

// Self-update of the gateway: checks in with the update server (the same
// protocol as the apps, update_proto.go) an hour after start and every 6
// hours. With the server's "install automatically" it downloads its file,
// checks the SHA-256, replaces this program and exits; the service manager
// (procd, systemd, Windows) starts the new one. "Ask" is only logged: a
// headless gateway has nobody to ask.

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"time"

	"github.com/btcsuite/btcd/btcec/v2"
	"golang.org/x/crypto/curve25519"
)

// updateServer: the server code built in (-ldflags -X main.updateServer=…).
var updateServer = ""

var (
	updateFirstCheck = time.Hour
	updateEvery      = 6 * time.Hour
)

// gatewayPackage: which release file updates this program.
func gatewayPackage() string {
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "linux/amd64":
		return "gateway-linux-x86_64"
	case "linux/arm64":
		return "gateway-linux-arm64"
	case "linux/arm":
		goarm := "7"
		if bi, ok := debug.ReadBuildInfo(); ok {
			for _, s := range bi.Settings {
				if s.Key == "GOARM" {
					goarm = strings.TrimSuffix(s.Value, ",softfloat")
				}
			}
		}
		if goarm == "6" || goarm == "5" {
			return "gateway-linux-armv6"
		}
		return "gateway-linux-armv7"
	case "linux/mips":
		return "gateway-linux-mips"
	case "linux/mipsle":
		return "gateway-linux-mipsle"
	case "windows/amd64":
		return "gateway-windows-x86_64"
	case "windows/arm64":
		return "gateway-windows-arm64"
	}
	return ""
}

type updateOffer struct {
	Mode    string `json:"mode"`
	Message string `json:"message"`
	Target  *struct {
		Version   string `json:"version"`
		File      string `json:"file"`
		Size      int64  `json:"size"`
		SHA256    string `json:"sha256"`
		URL       string `json:"url"`
		Local     bool   `json:"local"`
		Downgrade bool   `json:"downgrade"`
	} `json:"target"`
}

func (g *gateway) runUpdates() {
	code := g.cfg.UpdateServer
	if code == "" {
		code = updateServer
	}
	if !g.cfg.Updates || code == "" {
		return
	}
	pub, err := parseUpdateCode(code)
	if err != nil {
		log.Printf("self-update off: %v", err)
		return
	}
	pkg := gatewayPackage()
	if pkg == "" {
		return
	}
	log.Printf("self-update on (checks the update server every 6 hours)")
	first := updateFirstCheck
	if g.cfg.UpdateDelay > 0 {
		first = time.Duration(g.cfg.UpdateDelay) * time.Second
	}
	if !g.sleep(first) {
		return
	}
	for {
		if err := g.updateOnce(pub, pkg); err != nil {
			log.Printf("self-update: %v", err)
		}
		if !g.sleep(updateEvery) {
			return
		}
	}
}

// updateSession opens an encrypted link to the update server.
func (g *gateway) updateSession(serverPub []byte) (*peerConn, error) {
	eph := newKeyPair()
	shared, err := curve25519.X25519(eph.priv, serverPub)
	if err != nil {
		return nil, err
	}
	content, linkSecret := updateSessionKeys(shared, eph.pub, serverPub)
	topic := updateTopic(serverPub)
	sid := randomHex(8)
	nc := newNostrClient(g.cfg.Relays, map[string]any{
		"kinds": []int{signalKind}, "#t": []string{topic}, "since": time.Now().Add(-time.Minute).Unix(),
	})
	nc.start()
	defer nc.close()
	deadline := time.Now().Add(10 * time.Second)
	for nc.connected() == 0 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if nc.connected() == 0 {
		return nil, errors.New("no relay connected")
	}
	box, _ := json.Marshal(map[string]any{"sid": sid, "c": g.candidates(), "ts": time.Now().Unix()})
	offer, _ := json.Marshal(map[string]string{
		"e": base64.StdEncoding.EncodeToString(eph.pub),
		"m": base64.StdEncoding.EncodeToString(sealMessage(content, box)),
	})
	key, _ := btcec.NewPrivateKey()
	nc.publish(signEvent(key, signalKind, [][]string{{"t", topic}}, string(offer)))
	timeout := time.After(20 * time.Second)
	var cands []string
wait:
	for {
		select {
		case e := <-nc.events:
			if strings.HasPrefix(e.Content, "{") {
				continue
			}
			raw, err := base64.StdEncoding.DecodeString(e.Content)
			if err != nil {
				continue
			}
			plain, err := openMessage(content, raw)
			if err != nil {
				continue
			}
			var a struct {
				Sid, Type string
				C         []string
			}
			if json.Unmarshal(plain, &a) == nil && a.Sid == sid && a.Type == "answer" {
				cands = a.C
				break wait
			}
		case <-timeout:
			return nil, errors.New("the update server didn't answer (offline?)")
		}
	}
	connID, pk := punchKeys(content, sid)
	link, err := g.mux.punch(connID, pk, parseCandidates(cands), 10*time.Second)
	if err != nil {
		return nil, err
	}
	return newPeerConn(link, linkSecret), nil
}

func (g *gateway) updateOnce(serverPub []byte, pkg string) error {
	c, err := g.updateSession(serverPub)
	if err != nil {
		return err
	}
	defer c.fail(nil)
	c.send(jsonFrame(tUpdCheck, map[string]any{"id": g.selfID, "name": g.cfg.Name, "package": pkg,
		"version": version, "os": runtime.GOOS + "/" + runtime.GOARCH}))
	var offer updateOffer
	select {
	case f := <-c.frames:
		if f.typ != tUpdInfo || json.Unmarshal(f.payload, &offer) != nil {
			return errors.New("unexpected answer")
		}
	case <-c.closed:
		return errors.New("the link closed")
	case <-time.After(15 * time.Second):
		return errors.New("no answer on the link")
	}
	t := offer.Target
	if t == nil {
		log.Printf("self-update: nothing to install%s", strings.TrimSuffix(" ("+offer.Message+")", " ()"))
		return nil
	}
	if offer.Mode != "auto" {
		log.Printf("self-update: the server offers %s (%s); set it to install automatically for gateways", t.Version, offer.Mode)
		return nil
	}
	log.Printf("self-update: installing %s", t.Version)
	dir, err := os.MkdirTemp("", "gundil-update")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	file := filepath.Join(dir, filepath.Base(t.File))
	got := false
	if t.Local {
		if err := receiveFile(c, t.File, file, t.Size); err != nil {
			log.Printf("self-update: from the server: %v", err)
		} else {
			got = true
		}
	}
	if !got {
		if t.URL == "" {
			return errors.New("the file is not available")
		}
		if err := fetchURL(t.URL, file); err != nil {
			return err
		}
	}
	if sum, _ := fileSHA256(file); sum != strings.ToLower(t.SHA256) {
		return errors.New("the downloaded file is damaged (SHA-256)")
	}
	if err := installGatewayFile(file); err != nil {
		return err
	}
	log.Printf("self-update: installed %s, restarting", t.Version)
	time.Sleep(500 * time.Millisecond)
	os.Exit(75) // Not 0: systemd (Restart=on-failure) and Windows restart it.
	return nil
}

func receiveFile(c *peerConn, name, dst string, size int64) error {
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	c.send(jsonFrame(tUpdGet, map[string]any{"file": name, "offset": 0}))
	var pos int64
	for {
		select {
		case f := <-c.frames:
			switch f.typ {
			case tUpdData:
				if len(f.payload) < 8 || int64(binary.BigEndian.Uint64(f.payload)) != pos {
					return errors.New("out of order data")
				}
				n, err := out.Write(f.payload[8:])
				if err != nil {
					return err
				}
				pos += int64(n)
			case tUpdEnd:
				var m struct {
					Ok    bool
					Error string
				}
				json.Unmarshal(f.payload, &m)
				if !m.Ok {
					return errors.New(m.Error)
				}
				if pos != size {
					return errors.New("incomplete")
				}
				return nil
			}
		case <-c.closed:
			return errors.New("the link closed")
		case <-time.After(30 * time.Second):
			return errors.New("the server stopped sending")
		}
	}
}

func fetchURL(url, dst string) error {
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("User-Agent", "gundil-gateway")
	resp, err := (&http.Client{Timeout: 30 * time.Minute}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download: %s", resp.Status)
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, resp.Body)
	return err
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), nil
}

// installGatewayFile takes the program out of the release file (tar.gz or
// zip) and puts it in place of the running one.
func installGatewayFile(archive string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	want := "gundil-gateway"
	if runtime.GOOS == "windows" {
		want += ".exe"
	}
	staged := exe + ".new"
	if err := extractOne(archive, want, staged); err != nil {
		return err
	}
	os.Chmod(staged, 0o755)
	if runtime.GOOS == "windows" {
		// A running .exe can be renamed but not overwritten.
		old := exe + ".old"
		os.Remove(old)
		if err := os.Rename(exe, old); err != nil {
			os.Remove(staged)
			return err
		}
	}
	if err := os.Rename(staged, exe); err != nil {
		os.Remove(staged)
		return err
	}
	return nil
}

func extractOne(archive, name, dst string) error {
	write := func(r io.Reader) error {
		out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
		if err != nil {
			return err
		}
		_, err = io.Copy(out, io.LimitReader(r, 100<<20))
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		return err
	}
	if strings.HasSuffix(archive, ".zip") {
		z, err := zip.OpenReader(archive)
		if err != nil {
			return err
		}
		defer z.Close()
		for _, f := range z.File {
			if filepath.Base(f.Name) == name {
				r, err := f.Open()
				if err != nil {
					return err
				}
				defer r.Close()
				return write(r)
			}
		}
		return errors.New("no program in the update")
	}
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return errors.New("no program in the update")
		}
		if err != nil {
			return err
		}
		if h.Typeflag == tar.TypeReg && filepath.Base(h.Name) == name {
			return write(tr)
		}
	}
}
