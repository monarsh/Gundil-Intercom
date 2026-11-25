package main

// One encrypted link (the app's PeerConnection): key exchange, then
// every frame sealed.

import (
	"errors"
	"log"
	"sync"
	"time"
)

type peerConn struct {
	link     *udpLink
	secret   []byte
	keys     keyPair
	mu       sync.Mutex
	sealer   *frameCipher
	opener   *frameCipher
	opened   bool
	queue    []frame
	remoteID string
	frames   chan frame
	closed   chan struct{}
	once     sync.Once
}

func newPeerConn(link *udpLink, secret []byte) *peerConn {
	c := &peerConn{link: link, secret: secret, keys: newKeyPair(),
		frames: make(chan frame, 256), closed: make(chan struct{})}
	link.write(frame{tKey, append([]byte{keyExchangeVersion}, c.keys.pub...)}.encode())
	go c.readLoop()
	go func() {
		select {
		case <-time.After(6 * time.Second):
			c.mu.Lock()
			ok := c.opened
			c.mu.Unlock()
			if !ok {
				c.fail(errors.New("no key exchange (different password?)"))
			}
		case <-c.closed:
		}
	}()
	return c
}

func (c *peerConn) readLoop() {
	var dec frameDecoder
	defer c.fail(nil)
	for {
		select {
		case d := <-c.link.data:
			fs, err := dec.add(d)
			if err != nil {
				c.fail(err)
				return
			}
			for _, f := range fs {
				if !c.onFrame(f) {
					return
				}
			}
		case <-c.link.done:
			return
		case <-c.closed:
			return
		}
	}
}

func (c *peerConn) onFrame(f frame) bool {
	c.mu.Lock()
	if c.opener != nil {
		op := c.opener
		c.mu.Unlock()
		if f.typ != tSealed {
			return true
		}
		typ, p, err := op.open(f.payload)
		if err != nil {
			c.fail(errors.New("frame did not decrypt (different password?)"))
			return false
		}
		c.mu.Lock()
		c.opened = true
		c.mu.Unlock()
		if typ == tKey || typ == tSealed {
			return true
		}
		select {
		case c.frames <- frame{typ, p}:
		case <-c.closed:
			return false
		}
		return true
	}
	c.mu.Unlock()
	if f.typ != tKey || len(f.payload) != 33 || f.payload[0] != keyExchangeVersion {
		c.fail(errors.New("bad key exchange"))
		return false
	}
	k, err := deriveSession(c.keys, f.payload[1:], c.secret)
	if err != nil {
		c.fail(err)
		return false
	}
	c.mu.Lock()
	c.sealer = &frameCipher{key: k.send}
	c.opener = &frameCipher{key: k.receive}
	q := c.queue
	c.queue = nil
	c.mu.Unlock()
	for _, qf := range q {
		c.send(qf)
	}
	return true
}

func (c *peerConn) send(f frame) {
	c.mu.Lock()
	if c.sealer == nil {
		c.queue = append(c.queue, f)
		c.mu.Unlock()
		return
	}
	sealed := c.sealer.seal(f.typ, f.payload)
	c.mu.Unlock()
	c.link.write(frame{tSealed, sealed}.encode())
}

func (c *peerConn) fail(err error) {
	c.once.Do(func() {
		if err != nil {
			log.Printf("link to %s closed: %v", c.link.addr, err)
		}
		close(c.closed)
		c.link.close()
	})
}
