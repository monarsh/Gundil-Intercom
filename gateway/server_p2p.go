//go:build updateserver

package main

// The update server on the internet: listens for offers on the relays,
// punches through to the device, and answers its check-in on the
// encrypted link (see update_proto.go).

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/btcsuite/btcd/btcec/v2"
	"golang.org/x/crypto/curve25519"
)

const (
	updSignalKind = 21078
	updChunk      = 16 * 1024
	updPending    = 512 * 1024
)

type updateServer struct {
	cfg   *serverConfig
	st    *store
	key   keyPair
	topic string
	priv  *btcec.PrivateKey
	mux   *udpMux
	nostr *nostrClient
	links atomic.Int32

	seenMu sync.Mutex
	seen   map[string]time.Time // Offer sids already answered.

	stunMu sync.Mutex
	public *net.UDPAddr
	nat    string
	stunAt time.Time
}

func newUpdateServer(cfg *serverConfig, st *store) (*updateServer, error) {
	nk, _ := hex.DecodeString(st.keys.NostrKey)
	priv, _ := btcec.PrivKeyFromBytes(nk)
	mux, err := newUDPMux()
	if err != nil {
		return nil, err
	}
	s := &updateServer{cfg: cfg, st: st, key: st.serverKey(), priv: priv, mux: mux,
		seen: map[string]time.Time{}}
	s.topic = updateTopic(s.key.pub)
	s.nostr = newNostrClient(cfg.Relays, map[string]any{
		"kinds": []int{updSignalKind},
		"#t":    []string{s.topic},
		"since": time.Now().Add(-2 * time.Minute).Unix(),
	})
	return s, nil
}

func (s *updateServer) code() string { return updateCodeText(s.key.pub) }

func (s *updateServer) run() {
	s.nostr.start()
	go s.stun(true)
	for e := range s.nostr.events {
		s.onEvent(e)
	}
}

func (s *updateServer) stun(fresh bool) (*net.UDPAddr, string) {
	s.stunMu.Lock()
	defer s.stunMu.Unlock()
	if !fresh && time.Since(s.stunAt) < time.Minute {
		return s.public, s.nat
	}
	s.public, s.nat = s.mux.stun.check(s.cfg.Stun)
	s.stunAt = time.Now()
	if s.public != nil {
		log.Printf("STUN: public address %v, NAT %s", s.public, s.nat)
	} else {
		log.Printf("STUN: no answer (no internet?)")
	}
	return s.public, s.nat
}

func (s *updateServer) candidates() []string {
	var out []string
	if pub, _ := s.stun(false); pub != nil {
		out = append(out, pub.String())
	}
	for _, a := range ownIPv4() {
		out = append(out, fmt.Sprintf("%s:%d", a, s.mux.port()))
	}
	return out
}

func ownIPv4() []string {
	var out []string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok {
			if ip := ipn.IP.To4(); ip != nil && !ip.IsLoopback() {
				out = append(out, ip.String())
			}
		}
	}
	return out
}

func parseCandidates(cs []string) []*net.UDPAddr {
	var out []*net.UDPAddr
	for _, c := range cs {
		a, err := net.ResolveUDPAddr("udp4", c)
		if err == nil && a.IP.To4() != nil && a.Port > 0 {
			out = append(out, a)
		}
		if len(out) == 8 {
			break
		}
	}
	return out
}

// onEvent: an offer is {"e": device's ephemeral key, "m": sealed
// {"sid","c","ts"}}; anything else (answers, other junk) is skipped.
func (s *updateServer) onEvent(e nostrEvent) {
	if e.Kind != updSignalKind || !strings.HasPrefix(e.Content, "{") {
		return
	}
	var o struct{ E, M string }
	if json.Unmarshal([]byte(e.Content), &o) != nil {
		return
	}
	epub, err := base64.StdEncoding.DecodeString(o.E)
	if err != nil || len(epub) != 32 {
		return
	}
	box, err := base64.StdEncoding.DecodeString(o.M)
	if err != nil {
		return
	}
	shared, err := curve25519.X25519(s.key.priv, epub)
	if err != nil {
		return
	}
	content, linkSecret := updateSessionKeys(shared, epub, s.key.pub)
	plain, err := openMessage(content, box)
	if err != nil {
		return // Not for this server.
	}
	var m struct {
		Sid string
		C   []string
		Ts  int64
	}
	if json.Unmarshal(plain, &m) != nil || m.Sid == "" || len(m.Sid) > 64 {
		return
	}
	if d := time.Since(time.Unix(m.Ts, 0)); d > 2*time.Minute || d < -2*time.Minute {
		return
	}
	s.seenMu.Lock()
	for k, t := range s.seen {
		if time.Since(t) > 5*time.Minute {
			delete(s.seen, k)
		}
	}
	_, dup := s.seen[m.Sid] // The same offer from several relays.
	s.seen[m.Sid] = time.Now()
	s.seenMu.Unlock()
	if dup {
		return
	}
	if int(s.links.Load()) >= s.cfg.MaxLinks {
		log.Printf("busy (%d links): offer %s left for later", s.links.Load(), m.Sid[:min(8, len(m.Sid))])
		return
	}
	go s.answer(m.Sid, m.C, content, linkSecret)
}

func (s *updateServer) answer(sid string, cands []string, content, linkSecret []byte) {
	s.links.Add(1)
	defer s.links.Add(-1)
	body, _ := json.Marshal(map[string]any{"sid": sid, "type": "answer", "c": s.candidates(),
		"ts": time.Now().Unix()})
	s.nostr.publish(signEvent(s.priv, updSignalKind, [][]string{{"t", s.topic}},
		base64.StdEncoding.EncodeToString(sealMessage(content, body))))
	connID, key := punchKeys(content, sid)
	link, err := s.mux.punch(connID, key, parseCandidates(cands), 10*time.Second)
	if err != nil {
		log.Printf("couldn't punch through to a device: %v", err)
		return
	}
	c := newPeerConn(link, linkSecret)
	s.serve(c)
}

type checkMsg struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Package string `json:"package"`
	Version string `json:"version"`
	OS      string `json:"os"`
}

// decide: what a device on [pkg] at [current] should install.
func (s *updateServer) decide(d *device) map[string]any {
	fam := familyOf(d.Package)
	if fam == "" {
		return map[string]any{"mode": "off", "message": "unknown package " + d.Package}
	}
	pol := s.st.policyFor(fam)
	target := pol.Target
	mode := pol.Mode
	if d.Pin != "" {
		target = d.Pin
		if mode == "off" {
			mode = "ask"
		}
	}
	if target == "latest" {
		target = s.st.latestFor(d.Package)
	}
	out := map[string]any{"mode": mode}
	if mode == "off" || target == "" || compareVersions(target, d.Version) == 0 {
		return out
	}
	f := s.st.fileFor(target, d.Package)
	if f == nil {
		out["message"] = fmt.Sprintf("version %s has no file for %s", target, d.Package)
		return out
	}
	out["target"] = map[string]any{"version": target, "file": f.Name, "size": f.Size,
		"sha256": f.SHA256, "url": f.URL, "local": f.Local,
		"downgrade": compareVersions(target, d.Version) < 0}
	return out
}

func (s *updateServer) serve(c *peerConn) {
	defer c.fail(nil)
	var dev *device
	timeout := time.NewTimer(2 * time.Minute)
	defer timeout.Stop()
	for {
		var f frame
		select {
		case f = <-c.frames:
		case <-c.closed:
			return
		case <-timeout.C:
			return
		}
		switch f.typ {
		case tPing:
			c.send(frame{typ: tPong})
		case tUpdCheck:
			var m checkMsg
			if json.Unmarshal(f.payload, &m) != nil || len(m.ID) < 8 || len(m.ID) > 64 {
				return
			}
			dev = s.st.checkIn(device{ID: m.ID, Name: clip(m.Name, 64), Package: clip(m.Package, 40),
				Version: clip(m.Version, 20), OS: clip(m.OS, 80), Address: c.link.addr.IP.String()})
			info := s.decide(dev)
			if t, ok := info["target"].(map[string]any); ok {
				v := t["version"].(string)
				s.st.updateDevice(dev.ID, func(d *device) { d.Offered = v })
				log.Printf("%s (%s %s) checked in: offered %s", dev.Name, dev.Package, dev.Version, v)
			} else {
				log.Printf("%s (%s %s) checked in: nothing to do", dev.Name, dev.Package, dev.Version)
			}
			c.send(jsonFrame(tUpdInfo, info))
		case tUpdGet:
			var m struct {
				File   string
				Offset int64
			}
			if json.Unmarshal(f.payload, &m) != nil || dev == nil {
				return
			}
			timeout.Reset(6 * time.Hour) // A big file over a slow link.
			go s.sendFile(c, dev, m.File, m.Offset)
		}
	}
}

func (s *updateServer) sendFile(c *peerConn, dev *device, name string, offset int64) {
	fail := func(msg string) {
		log.Printf("sending %s to %s: %s", name, dev.Name, msg)
		c.send(jsonFrame(tUpdEnd, map[string]any{"ok": false, "error": msg}))
	}
	path, vf := s.st.localFile(name)
	if vf == nil {
		fail("not kept on this server")
		return
	}
	fh, err := os.Open(path)
	if err != nil {
		fail("file missing")
		return
	}
	defer fh.Close()
	if offset < 0 || offset > vf.Size {
		offset = 0
	}
	if _, err := fh.Seek(offset, io.SeekStart); err != nil {
		fail(err.Error())
		return
	}
	log.Printf("sending %s to %s (from %d of %d bytes)", name, dev.Name, offset, vf.Size)
	buf := make([]byte, updChunk)
	pos := offset
	start := time.Now()
	for {
		n, err := fh.Read(buf)
		if n > 0 {
			p := make([]byte, 8+n)
			binary.BigEndian.PutUint64(p, uint64(pos))
			copy(p[8:], buf[:n])
			c.send(frame{tUpdData, p})
			pos += int64(n)
			for c.link.pending() > updPending {
				select {
				case <-c.closed:
					log.Printf("%s: link closed at %d of %d bytes", dev.Name, pos, vf.Size)
					return
				case <-time.After(50 * time.Millisecond):
				}
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			fail(err.Error())
			return
		}
	}
	c.send(jsonFrame(tUpdEnd, map[string]any{"ok": true}))
	secs := time.Since(start).Seconds()
	log.Printf("sent %s to %s (%d KB in %.0f s)", name, dev.Name, (pos-offset)/1024, secs)
	s.st.updateDevice(dev.ID, func(d *device) { d.Fetched = name })
}

func clip(s string, n int) string {
	s = strings.Map(func(r rune) rune {
		if r < 32 {
			return -1
		}
		return r
	}, s)
	if len([]rune(s)) > n {
		return string([]rune(s)[:n])
	}
	return s
}

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
