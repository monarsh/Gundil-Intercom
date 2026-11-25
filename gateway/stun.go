package main

import (
	"crypto/rand"
	"encoding/binary"
	"net"
	"sync"
	"time"
)

const stunMagic = 0x2112A442

var defaultStunServers = []string{
	"stun.l.google.com:19302",
	"stun1.l.google.com:19302",
	"stun.cloudflare.com:3478",
}

func isStun(p []byte) bool {
	return len(p) >= 20 && p[0]&0xC0 == 0 && binary.BigEndian.Uint32(p[4:8]) == stunMagic
}

type stunClient struct {
	send    func(b []byte, to *net.UDPAddr)
	mu      sync.Mutex
	pending map[[12]byte]chan *net.UDPAddr
}

func newStunClient(send func([]byte, *net.UDPAddr)) *stunClient {
	return &stunClient{send: send, pending: map[[12]byte]chan *net.UDPAddr{}}
}

// handle takes a STUN answer (returns false for other packets).
func (s *stunClient) handle(p []byte) bool {
	if !isStun(p) {
		return false
	}
	var id [12]byte
	copy(id[:], p[8:20])
	s.mu.Lock()
	ch := s.pending[id]
	delete(s.pending, id)
	s.mu.Unlock()
	if ch == nil || binary.BigEndian.Uint16(p[0:2]) != 0x0101 {
		return true
	}
	n := int(binary.BigEndian.Uint16(p[2:4]))
	end := 20 + n
	if end > len(p) {
		end = len(p)
	}
	for off := 20; off+4 <= end; {
		typ := binary.BigEndian.Uint16(p[off:])
		l := int(binary.BigEndian.Uint16(p[off+2:]))
		v := off + 4
		if v+l > end {
			break
		}
		if (typ == 0x0020 || typ == 0x0001) && l >= 8 && p[v+1] == 1 {
			port := binary.BigEndian.Uint16(p[v+2:])
			ip := net.IP(append([]byte(nil), p[v+4:v+8]...))
			if typ == 0x0020 {
				port ^= uint16(stunMagic >> 16)
				for k := 0; k < 4; k++ {
					ip[k] ^= byte(uint32(stunMagic) >> (24 - 8*k))
				}
			}
			ch <- &net.UDPAddr{IP: ip, Port: int(port)}
			return true
		}
		off = v + (l+3)&^3
	}
	return true
}

func (s *stunClient) query(server string, timeout time.Duration) *net.UDPAddr {
	addr, err := net.ResolveUDPAddr("udp4", server)
	if err != nil {
		return nil
	}
	var id [12]byte
	rand.Read(id[:])
	ch := make(chan *net.UDPAddr, 1)
	s.mu.Lock()
	s.pending[id] = ch
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.pending, id)
		s.mu.Unlock()
	}()
	req := make([]byte, 20)
	binary.BigEndian.PutUint16(req[0:], 0x0001)
	binary.BigEndian.PutUint32(req[4:], stunMagic)
	copy(req[8:], id[:])
	deadline := time.Now().Add(timeout)
	wait := 250 * time.Millisecond
	for time.Now().Before(deadline) {
		s.send(req, addr)
		select {
		case r := <-ch:
			return r
		case <-time.After(wait):
			wait *= 2
		}
	}
	return nil
}

// check asks the servers: the public address, and "cone" (one public port
// for every destination: hole punching works) or "symmetric".
func (s *stunClient) check(servers []string) (*net.UDPAddr, string) {
	results := make([]*net.UDPAddr, len(servers))
	var wg sync.WaitGroup
	for i, srv := range servers {
		wg.Add(1)
		go func(i int, srv string) {
			defer wg.Done()
			results[i] = s.query(srv, 3*time.Second)
		}(i, srv)
	}
	wg.Wait()
	var ok []*net.UDPAddr
	for _, r := range results {
		if r != nil {
			ok = append(ok, r)
		}
	}
	if len(ok) == 0 {
		return nil, "unknown"
	}
	if len(ok) < 2 {
		return ok[0], "unknown"
	}
	for _, r := range ok[1:] {
		if r.Port != ok[0].Port || !r.IP.Equal(ok[0].IP) {
			return ok[0], "symmetric"
		}
	}
	return ok[0], "cone"
}
