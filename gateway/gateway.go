//go:build !updateserver

package main

// The gateway itself: shows up on the relays as an intercom that shares
// its LAN, answers offers by punching, and passes camera connections
// through (tunnel frames). It can't be called: no audio.

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/btcsuite/btcd/btcec/v2"
)

const (
	presenceKind = 30078
	signalKind   = 21078
	maxPending   = 512 * 1024
	tunnelChunk  = 16 * 1024
)

type gateway struct {
	cfg     *config
	selfID  string
	priv    *btcec.PrivateKey
	keys    rendezvousKeys
	secret  []byte
	mux     *udpMux
	nostr   *nostrClient
	share   bool
	anyHost bool // Tests: tunnels to any address.

	stunMu sync.Mutex
	public *net.UDPAddr
	nat    string
	stunAt time.Time

	done     chan struct{} // Closed by stop().
	stopOnce sync.Once
}

func newGateway(cfg *config, st *state, scryptN int) (*gateway, error) {
	kb, err := hex.DecodeString(st.NostrKey)
	if err != nil || len(kb) != 32 {
		return nil, fmt.Errorf("bad nostr key in the state file")
	}
	priv, _ := btcec.PrivKeyFromBytes(kb)
	mux, err := newUDPMux()
	if err != nil {
		return nil, err
	}
	g := &gateway{cfg: cfg, selfID: st.DeviceID, priv: priv,
		mux: mux, share: cfg.ShareCameras, anyHost: cfg.AnyHost, done: make(chan struct{})}
	if cfg.Password != "" {
		g.keys, g.secret = deriveRendezvous(cfg.Password, scryptN), networkSecret(cfg.Password)
	} else {
		g.keys, g.secret = homeRendezvous(cfg.HomeKey), homeLinkSecret(cfg.HomeKey)
	}
	since := time.Now().Add(-15 * time.Minute).Unix()
	g.nostr = newNostrClient(cfg.Relays, map[string]any{
		"kinds": []int{presenceKind, signalKind},
		"#t":    []string{g.keys.topic},
		"since": since,
	})
	g.nostr.onConnect = g.announce
	return g, nil
}

// run serves until stop().
func (g *gateway) run() {
	g.nostr.start()
	go g.stun(true)
	go g.runUpdates()
	go func() {
		t := time.NewTicker(5 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-g.done:
				return
			case <-t.C:
				g.announce()
			}
		}
	}()
	for {
		select {
		case <-g.done:
			return
		case e := <-g.nostr.events:
			g.onEvent(e)
		}
	}
}

// stop ends run(), the relays, the UDP socket and its links (the web page
// restarts the gateway this way after its settings changed).
func (g *gateway) stop() {
	g.stopOnce.Do(func() {
		close(g.done)
		g.nostr.close()
		g.mux.close()
	})
}

// sleep waits [d]; false when the gateway stopped meanwhile.
func (g *gateway) sleep(d time.Duration) bool {
	select {
	case <-g.done:
		return false
	case <-time.After(d):
		return true
	}
}

// lastStun: the latest STUN result, without asking again.
func (g *gateway) lastStun() (string, string) {
	g.stunMu.Lock()
	defer g.stunMu.Unlock()
	pub := ""
	if g.public != nil {
		pub = g.public.String()
	}
	return pub, g.nat
}

func (g *gateway) stun(fresh bool) (*net.UDPAddr, string) {
	g.stunMu.Lock()
	defer g.stunMu.Unlock()
	if !fresh && time.Since(g.stunAt) < time.Minute {
		return g.public, g.nat
	}
	g.public, g.nat = g.mux.stun.check(g.cfg.Stun)
	g.stunAt = time.Now()
	log.Printf("STUN: public address %v, NAT %s", g.public, g.nat)
	return g.public, g.nat
}

func (g *gateway) seal(v any) string {
	b, _ := json.Marshal(v)
	return base64.StdEncoding.EncodeToString(sealMessage(g.keys.contentKey, b))
}

func (g *gateway) announce() {
	now := time.Now().Unix()
	subnets := []string{}
	if g.share {
		subnets, _ = localSubnets()
		if len(g.cfg.TestSubnets) > 0 {
			subnets = g.cfg.TestSubnets
		}
	}
	body := map[string]any{"id": g.selfID, "name": g.cfg.Name, "platform": "gundil-gateway",
		"v": protocolVersion, "ts": now}
	if len(subnets) > 0 {
		body["subnets"] = subnets
	}
	e := signEvent(g.priv, presenceKind, [][]string{
		{"d", "gundil:" + g.keys.topic + ":" + g.selfID},
		{"t", g.keys.topic},
		{"expiration", strconv.FormatInt(now+900, 10)},
	}, g.seal(body))
	n := g.nostr.publish(e)
	if n > 0 {
		log.Printf("presence sent to %d relays (sharing %v)", n, subnets)
	}
}

func (g *gateway) onEvent(e nostrEvent) {
	if e.Kind != signalKind {
		return
	}
	hasTopic := false
	for _, t := range e.Tags {
		if len(t) >= 2 && t[0] == "t" && t[1] == g.keys.topic {
			hasTopic = true
		}
	}
	if !hasTopic {
		return
	}
	raw, err := base64.StdEncoding.DecodeString(e.Content)
	if err != nil {
		return
	}
	plain, err := openMessage(g.keys.contentKey, raw)
	if err != nil {
		return // Another password.
	}
	var s struct {
		From, To, Sid, Type string
		C                   []string
		Ts                  int64
	}
	if json.Unmarshal(plain, &s) != nil || s.To != g.selfID || s.Type != "offer" {
		return
	}
	if d := time.Since(time.Unix(s.Ts, 0)); d > 2*time.Minute || d < -2*time.Minute {
		return
	}
	go g.answer(s.From, s.Sid, s.C)
}

func (g *gateway) candidates() []string {
	var out []string
	if pub, _ := g.stun(false); pub != nil {
		out = append(out, pub.String())
	}
	_, own := localAddrs()
	for _, a := range own {
		out = append(out, fmt.Sprintf("%s:%d", a, g.mux.port()))
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
	}
	return out
}

func (g *gateway) answer(from, sid string, cands []string) {
	log.Printf("offer from %s: answering and punching", from)
	body := map[string]any{"from": g.selfID, "to": from, "sid": sid, "type": "answer",
		"c": g.candidates(), "ts": time.Now().Unix()}
	g.nostr.publish(signEvent(g.priv, signalKind, [][]string{{"t", g.keys.topic}}, g.seal(body)))
	connID, key := punchKeys(g.keys.contentKey, sid)
	link, err := g.mux.punch(connID, key, parseCandidates(cands), 10*time.Second)
	if err != nil {
		log.Printf("couldn't punch through to %s: %v", from, err)
		return
	}
	go g.serveLink(newPeerConn(link, g.secret))
}

func (g *gateway) hello() frame {
	return jsonFrame(tHello, map[string]any{"id": g.selfID, "name": g.cfg.Name,
		"platform": "gundil-gateway", "port": 0, "v": protocolVersion})
}

type tunnel struct {
	tid    uint32
	conn   net.Conn
	writes chan []byte
	once   sync.Once
}

func (g *gateway) serveLink(c *peerConn) {
	c.send(frame{typ: tPing}) // Proves the password at once, like the app.
	tunnels := map[uint32]*tunnel{}
	var mu sync.Mutex
	closeTunnel := func(t *tunnel, notify bool) {
		t.once.Do(func() {
			t.conn.Close()
			close(t.writes)
			mu.Lock()
			delete(tunnels, t.tid)
			mu.Unlock()
			if notify {
				b := make([]byte, 4)
				binary.BigEndian.PutUint32(b, t.tid)
				c.send(frame{tTunnelClose, b})
			}
		})
	}
	defer func() {
		mu.Lock()
		all := make([]*tunnel, 0, len(tunnels))
		for _, t := range tunnels {
			all = append(all, t)
		}
		mu.Unlock()
		for _, t := range all {
			closeTunnel(t, false)
		}
	}()
	for {
		var f frame
		select {
		case f = <-c.frames:
		case <-c.closed:
			return
		}
		switch f.typ {
		case tHello:
			var m struct{ ID string }
			json.Unmarshal(f.payload, &m)
			c.remoteID = m.ID
			c.send(g.hello())
			log.Printf("link up with %s (%s)", m.ID, c.link.addr)
		case tPing:
			c.send(frame{typ: tPong})
		case tOpen:
			c.send(jsonFrame(tReject, map[string]any{"reason": "declined"}))
		case tTunnelOpen:
			var m struct {
				Tid  uint32
				Host string
				Port int
			}
			if json.Unmarshal(f.payload, &m) != nil {
				continue
			}
			go func() {
				t, err := g.openTunnel(c, m.Tid, m.Host, m.Port)
				reply := map[string]any{"tid": m.Tid, "ok": err == nil}
				if err != nil {
					reply["error"] = err.Error()
					log.Printf("tunnel to %s:%d refused: %v", m.Host, m.Port, err)
					c.send(jsonFrame(tTunnelReply, reply))
					return
				}
				mu.Lock()
				tunnels[m.Tid] = t
				mu.Unlock()
				c.send(jsonFrame(tTunnelReply, reply))
				log.Printf("tunnel to %s:%d opened for %s", m.Host, m.Port, c.remoteID)
				go func() { // Link → camera.
					for b := range t.writes {
						if _, err := t.conn.Write(b); err != nil {
							closeTunnel(t, true)
							return
						}
					}
				}()
				buf := make([]byte, tunnelChunk)
				for { // Camera → link, slowed while the link is behind.
					n, err := t.conn.Read(buf)
					if n > 0 {
						p := make([]byte, 4+n)
						binary.BigEndian.PutUint32(p, t.tid)
						copy(p[4:], buf[:n])
						c.send(frame{tTunnelData, p})
						for c.link.pending() > maxPending {
							time.Sleep(50 * time.Millisecond)
							select {
							case <-c.closed:
								closeTunnel(t, false)
								return
							default:
							}
						}
					}
					if err != nil {
						closeTunnel(t, true)
						return
					}
				}
			}()
		case tTunnelData:
			if len(f.payload) < 4 {
				continue
			}
			mu.Lock()
			t := tunnels[binary.BigEndian.Uint32(f.payload)]
			mu.Unlock()
			if t != nil {
				func() {
					defer func() { recover() }() // Closed meanwhile.
					t.writes <- f.payload[4:]
				}()
			}
		case tTunnelClose:
			if len(f.payload) < 4 {
				continue
			}
			mu.Lock()
			t := tunnels[binary.BigEndian.Uint32(f.payload)]
			mu.Unlock()
			if t != nil {
				closeTunnel(t, false)
			}
		}
	}
}

func (g *gateway) openTunnel(c *peerConn, tid uint32, host string, port int) (*tunnel, error) {
	if !g.share {
		return nil, fmt.Errorf("this gateway does not share its cameras")
	}
	if port <= 0 || port > 65535 {
		return nil, fmt.Errorf("bad port")
	}
	if !g.anyHost {
		nets, own := localAddrs()
		ok := false
		for _, n := range nets {
			if inSubnet(host, n) {
				ok = true
			}
		}
		for _, a := range own {
			if a == host {
				ok = false
			}
		}
		if !ok {
			return nil, fmt.Errorf("%s is not on the gateway's LAN", host)
		}
	}
	conn, err := net.DialTimeout("tcp4", net.JoinHostPort(host, strconv.Itoa(port)), 5*time.Second)
	if err != nil {
		return nil, err
	}
	return &tunnel{tid: tid, conn: conn, writes: make(chan []byte, 256)}, nil
}

// localAddrs: the /24 networks of the private IPv4 addresses, and the
// addresses (the app's tunnel.dart does the same).
func localAddrs() ([]string, []string) {
	nets := map[string]bool{}
	var own []string
	ifaces, _ := net.InterfaceAddrs()
	for _, a := range ifaces {
		ipn, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ip := ipn.IP.To4()
		if ip == nil || ip.IsLoopback() || !ip.IsPrivate() {
			continue
		}
		own = append(own, ip.String())
		nets[fmt.Sprintf("%d.%d.%d.0/24", ip[0], ip[1], ip[2])] = true
	}
	var out []string
	for n := range nets {
		out = append(out, n)
	}
	sort.Strings(out)
	return out, own
}

func localSubnets() ([]string, error) {
	n, _ := localAddrs()
	return n, nil
}

func inSubnet(host, subnet string) bool {
	ip := net.ParseIP(host).To4()
	if ip == nil {
		return false
	}
	return subnet == fmt.Sprintf("%d.%d.%d.0/24", ip[0], ip[1], ip[2])
}

// checkReport: what --check prints and the web page shows.
type checkReport struct {
	Key         string   `json:"key"` // "password" or the home key's fingerprint.
	Relays      int      `json:"relays"`
	RelaysTotal int      `json:"relaysTotal"`
	NAT         string   `json:"nat"` // cone, symmetric, unknown
	NATText     string   `json:"natText"`
	Public      string   `json:"public"`
	Share       bool     `json:"share"`
	Subnets     []string `json:"subnets"`
	Cameras     []string `json:"cameras"` // One line per check_hosts entry.
}

// runCheck waits (up to 8 s) for the relays, asks STUN, and tries the
// check_hosts.
func (g *gateway) runCheck() checkReport {
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) && g.nostr.connected() < len(g.cfg.Relays) {
		time.Sleep(200 * time.Millisecond)
	}
	pub, nat := g.stun(true)
	r := checkReport{Relays: g.nostr.connected(), RelaysTotal: len(g.cfg.Relays), NAT: nat, Share: g.share}
	r.NATText = map[string]string{
		"cone":      "direct calls likely (one public port per socket)",
		"symmetric": "direct calls may fail (strict NAT)",
		"unknown":   "unknown (no STUN server answered)",
	}[nat]
	if pub != nil {
		r.Public = pub.String()
	}
	r.Subnets, _ = localAddrs()
	if g.cfg.Password == "" {
		r.Key = homeFingerprint(g.cfg.HomeKey)
	} else {
		r.Key = "password"
	}
	for _, t := range g.cfg.CheckHosts {
		conn, err := net.DialTimeout("tcp4", t, 3*time.Second)
		if err != nil {
			r.Cameras = append(r.Cameras, fmt.Sprintf("%s does not answer: %v", t, err))
			continue
		}
		conn.Close()
		r.Cameras = append(r.Cameras, t+" answers")
	}
	return r
}

func (g *gateway) check() {
	r := g.runCheck()
	if r.Key == "password" {
		fmt.Printf("Key:     the intercom password\n")
	} else {
		fmt.Printf("Key:     home key %s (compare with the app)\n", r.Key)
	}
	fmt.Printf("Relays:  %d of %d connected\n", r.Relays, r.RelaysTotal)
	fmt.Printf("NAT:     %s\n", r.NATText)
	if r.Public == "" {
		fmt.Printf("Public:  <nil>\n")
	} else {
		fmt.Printf("Public:  %s\n", r.Public)
	}
	if r.Share {
		fmt.Printf("Shares:  %s\n", strings.Join(r.Subnets, ", "))
	} else {
		fmt.Printf("Shares:  nothing (share_cameras = false)\n")
	}
	for _, c := range r.Cameras {
		fmt.Printf("Camera:  %s\n", c)
	}
}
