package main

// Hole-punched UDP links, the same packets as the app's udp_link.dart:
//   [0xC7][kind][connId:4][...]
//   1 PUNCH [mac:16] · 2 PUNCH_OK [mac:16] · 3 DATA [seq:4][bytes]
//   4 ACK [next:4] · 5 DGRAM [msg:4][i][n][piece] · 6 CLOSE

import (
	"crypto/hmac"
	"encoding/binary"
	"errors"
	"log"
	"net"
	"sort"
	"sync"
	"time"
)

const (
	pTag     = 0xC7
	pPunch   = 1
	pPunchOK = 2
	pData    = 3
	pAck     = 4
	pDgram   = 5
	pClose   = 6
	segSize  = 1100
)

type punchWait struct {
	key  []byte
	done chan *udpLink
}

type udpMux struct {
	conn    *net.UDPConn
	stun    *stunClient
	mu      sync.Mutex
	links   map[uint32]*udpLink
	keys    map[uint32][]byte
	punches map[uint32]*punchWait
	closed  bool
}

func newUDPMux() (*udpMux, error) {
	c, err := net.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		return nil, err
	}
	m := &udpMux{conn: c, links: map[uint32]*udpLink{}, keys: map[uint32][]byte{},
		punches: map[uint32]*punchWait{}}
	m.stun = newStunClient(m.send)
	go m.read()
	return m, nil
}

func (m *udpMux) port() int { return m.conn.LocalAddr().(*net.UDPAddr).Port }

func (m *udpMux) send(b []byte, to *net.UDPAddr) {
	m.conn.WriteToUDP(b, to)
}

func header(kind byte, connID uint32, extra int) []byte {
	b := make([]byte, 6, 6+extra)
	b[0] = pTag
	b[1] = kind
	binary.BigEndian.PutUint32(b[2:], connID)
	return b
}

func (m *udpMux) read() {
	buf := make([]byte, 65536)
	for {
		n, from, err := m.conn.ReadFromUDP(buf)
		if err != nil {
			m.mu.Lock()
			closed := m.closed
			m.mu.Unlock()
			if closed {
				return
			}
			continue
		}
		p := append([]byte(nil), buf[:n]...)
		if len(p) == 0 {
			continue
		}
		if p[0] != pTag {
			m.stun.handle(p)
			continue
		}
		if len(p) < 6 {
			continue
		}
		kind := p[1]
		connID := binary.BigEndian.Uint32(p[2:6])
		body := p[6:]
		if kind == pPunch || kind == pPunchOK {
			m.mu.Lock()
			key := m.keys[connID]
			m.mu.Unlock()
			if key == nil || len(body) < 16 || !hmac.Equal(punchMAC(key, kind, connID), body[:16]) {
				continue
			}
			if kind == pPunch {
				m.send(append(header(pPunchOK, connID, 16), punchMAC(key, pPunchOK, connID)...), from)
			}
			m.mu.Lock()
			w := m.punches[connID]
			delete(m.punches, connID)
			var link *udpLink
			if w != nil {
				link = newUDPLink(m, connID, from)
				m.links[connID] = link
			}
			m.mu.Unlock()
			if w != nil {
				log.Printf("punched through to %s", from)
				w.done <- link
			}
			continue
		}
		m.mu.Lock()
		link := m.links[connID]
		m.mu.Unlock()
		if link != nil {
			link.onPacket(kind, body, from)
		}
	}
}

// punch sends punches to every candidate until the other side's arrives.
func (m *udpMux) punch(connID uint32, key []byte, cands []*net.UDPAddr, timeout time.Duration) (*udpLink, error) {
	w := &punchWait{key: key, done: make(chan *udpLink, 1)}
	m.mu.Lock()
	m.keys[connID] = key
	m.punches[connID] = w
	m.mu.Unlock()
	pkt := append(header(pPunch, connID, 16), punchMAC(key, pPunch, connID)...)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	deadline := time.After(timeout)
	for {
		for _, c := range cands {
			m.send(pkt, c)
		}
		select {
		case l := <-w.done:
			return l, nil
		case <-deadline:
			m.mu.Lock()
			delete(m.punches, connID)
			delete(m.keys, connID)
			m.mu.Unlock()
			return nil, errors.New("no answer to the punches (strict NAT?)")
		case <-tick.C:
		}
	}
}

func (m *udpMux) forget(connID uint32) {
	m.mu.Lock()
	delete(m.links, connID)
	delete(m.keys, connID)
	m.mu.Unlock()
}

func (m *udpMux) close() {
	m.mu.Lock()
	m.closed = true
	links := make([]*udpLink, 0, len(m.links))
	for _, l := range m.links {
		links = append(links, l)
	}
	m.mu.Unlock()
	for _, l := range links {
		l.close()
	}
	m.conn.Close()
}

type segment struct {
	seq    uint32
	data   []byte
	sentAt time.Time
	sends  int
}

// udpLink: a reliable ordered byte stream over one punched path (the
// gateway doesn't use datagrams: no audio or video).
type udpLink struct {
	mux    *udpMux
	connID uint32

	mu       sync.Mutex
	addr     *net.UDPAddr
	out      []byte
	inFlight map[uint32]*segment
	nextSeq  uint32
	cwnd     float64
	srtt     time.Duration
	lastAck  uint32
	dupAcks  int
	lastCut  time.Time
	expected uint32
	early    map[uint32][]byte
	heard    time.Time
	closed   bool

	data chan []byte // In order, to the reader.
	done chan struct{}
}

func newUDPLink(m *udpMux, connID uint32, addr *net.UDPAddr) *udpLink {
	l := &udpLink{mux: m, connID: connID, addr: addr, inFlight: map[uint32]*segment{},
		cwnd: 10, srtt: 300 * time.Millisecond, early: map[uint32][]byte{},
		heard: time.Now(), data: make(chan []byte, 1024), done: make(chan struct{})}
	go l.ticker()
	return l
}

func (l *udpLink) raw(kind byte, body []byte) {
	l.mux.send(append(header(kind, l.connID, len(body)), body...), l.addr)
}

func (l *udpLink) write(b []byte) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return errors.New("link closed")
	}
	l.out = append(l.out, b...)
	l.pump()
	return nil
}

// pending: bytes not yet acknowledged (to slow down a sender).
func (l *udpLink) pending() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := len(l.out)
	for _, s := range l.inFlight {
		n += len(s.data)
	}
	return n
}

func (l *udpLink) pump() {
	for len(l.out) > 0 && len(l.inFlight) < int(l.cwnd) {
		n := segSize
		if len(l.out) < n {
			n = len(l.out)
		}
		s := &segment{seq: l.nextSeq, data: append([]byte(nil), l.out[:n]...)}
		l.out = l.out[n:]
		l.nextSeq++
		l.inFlight[s.seq] = s
		l.transmit(s)
	}
}

func (l *udpLink) transmit(s *segment) {
	s.sentAt = time.Now()
	s.sends++
	b := make([]byte, 4+len(s.data))
	binary.BigEndian.PutUint32(b, s.seq)
	copy(b[4:], s.data)
	l.raw(pData, b)
}

func (l *udpLink) rto() time.Duration {
	r := l.srtt * 2
	if r < 200*time.Millisecond {
		r = 200 * time.Millisecond
	}
	if r > 3*time.Second {
		r = 3 * time.Second
	}
	return r
}

func (l *udpLink) ticker() {
	t := time.NewTicker(50 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-l.done:
			return
		case <-t.C:
		}
		l.mu.Lock()
		now := time.Now()
		if now.Sub(l.heard) > 100*time.Second {
			l.mu.Unlock()
			log.Printf("link to %s went silent", l.addr)
			l.shutdown(true)
			return
		}
		lost := false
		dead := false
		keys := make([]int, 0, len(l.inFlight))
		for k := range l.inFlight {
			keys = append(keys, int(k))
		}
		sort.Ints(keys)
		for _, k := range keys {
			s := l.inFlight[uint32(k)]
			shift := s.sends - 1
			if shift > 3 {
				shift = 3
			}
			r := l.rto() * time.Duration(1<<shift)
			if r > 3*time.Second {
				r = 3 * time.Second
			}
			if now.Sub(s.sentAt) >= r {
				if s.sends >= 15 {
					dead = true
					break
				}
				lost = true
				l.transmit(s)
			}
		}
		if lost && now.Sub(l.lastCut) > l.srtt {
			l.cwnd /= 2
			if l.cwnd < 4 {
				l.cwnd = 4
			}
			l.lastCut = now
		}
		l.mu.Unlock()
		if dead {
			l.shutdown(true)
			return
		}
	}
}

func (l *udpLink) onPacket(kind byte, body []byte, from *net.UDPAddr) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.heard = time.Now()
	if !from.IP.Equal(l.addr.IP) || from.Port != l.addr.Port {
		log.Printf("link moved: %s → %s", l.addr, from)
		l.addr = from
	}
	var deliver [][]byte
	switch {
	case kind == pData && len(body) >= 4:
		seq := binary.BigEndian.Uint32(body)
		if seq >= l.expected {
			if _, ok := l.early[seq]; !ok {
				l.early[seq] = append([]byte(nil), body[4:]...)
			}
		}
		for {
			d, ok := l.early[l.expected]
			if !ok {
				break
			}
			delete(l.early, l.expected)
			deliver = append(deliver, d)
			l.expected++
		}
		a := make([]byte, 4)
		binary.BigEndian.PutUint32(a, l.expected)
		l.raw(pAck, a)
	case kind == pAck && len(body) >= 4:
		l.onAck(binary.BigEndian.Uint32(body))
	case kind == pClose:
		l.mu.Unlock()
		l.shutdown(false)
		return
	}
	l.mu.Unlock()
	for _, d := range deliver {
		select {
		case l.data <- d:
		case <-l.done:
			return
		}
	}
}

func (l *udpLink) onAck(next uint32) {
	if next == l.lastAck {
		l.dupAcks++
		if l.dupAcks == 3 {
			if s := l.inFlight[next]; s != nil {
				now := time.Now()
				if now.Sub(l.lastCut) > l.srtt {
					l.cwnd /= 2
					if l.cwnd < 4 {
						l.cwnd = 4
					}
					l.lastCut = now
				}
				l.transmit(s)
			}
		}
		return
	}
	if next < l.lastAck {
		return
	}
	l.lastAck = next
	l.dupAcks = 0
	now := time.Now()
	for k, s := range l.inFlight {
		if k < next {
			delete(l.inFlight, k)
			if s.sends == 1 {
				l.srtt = (l.srtt*7 + now.Sub(s.sentAt)) / 8
			}
			l.cwnd += 1 / l.cwnd
			if l.cwnd > 256 {
				l.cwnd = 256
			}
		}
	}
	l.pump()
}

func (l *udpLink) close() { l.shutdown(true) }

func (l *udpLink) shutdown(notify bool) {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return
	}
	l.closed = true
	if notify {
		l.raw(pClose, nil)
	}
	l.mu.Unlock()
	l.mux.forget(l.connID)
	close(l.done)
}
