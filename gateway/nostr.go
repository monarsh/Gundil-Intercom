package main

// A minimal Nostr client: several relays at once, one subscription, events
// signed with BIP-340 Schnorr (the app's nostr.dart).

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/schnorr"
	"github.com/coder/websocket"
)

var defaultRelays = []string{
	"wss://relay.damus.io",
	"wss://nos.lol",
	"wss://relay.primal.net",
	"wss://nostr.mom",
	"wss://relay.nostr.band",
}

type nostrEvent struct {
	ID        string     `json:"id"`
	Pubkey    string     `json:"pubkey"`
	CreatedAt int64      `json:"created_at"`
	Kind      int        `json:"kind"`
	Tags      [][]string `json:"tags"`
	Content   string     `json:"content"`
	Sig       string     `json:"sig"`
}

func canonical(v any) []byte {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	e.Encode(v)
	return bytes.TrimRight(b.Bytes(), "\n")
}

func eventID(pub string, at int64, kind int, tags [][]string, content string) string {
	if tags == nil {
		tags = [][]string{}
	}
	h := sha256.Sum256(canonical([]any{0, pub, at, kind, tags, content}))
	return hex.EncodeToString(h[:])
}

func signEvent(priv *btcec.PrivateKey, kind int, tags [][]string, content string) nostrEvent {
	pub := hex.EncodeToString(schnorr.SerializePubKey(priv.PubKey()))
	at := time.Now().Unix()
	id := eventID(pub, at, kind, tags, content)
	idb, _ := hex.DecodeString(id)
	sig, err := schnorr.Sign(priv, idb)
	if err != nil {
		panic(err)
	}
	return nostrEvent{id, pub, at, kind, tags, content, hex.EncodeToString(sig.Serialize())}
}

func (e nostrEvent) valid() bool {
	if eventID(e.Pubkey, e.CreatedAt, e.Kind, e.Tags, e.Content) != e.ID {
		return false
	}
	pb, err1 := hex.DecodeString(e.Pubkey)
	sb, err2 := hex.DecodeString(e.Sig)
	idb, err3 := hex.DecodeString(e.ID)
	if err1 != nil || err2 != nil || err3 != nil {
		return false
	}
	pub, err := schnorr.ParsePubKey(pb)
	if err != nil {
		return false
	}
	sig, err := schnorr.ParseSignature(sb)
	if err != nil {
		return false
	}
	return sig.Verify(idb, pub)
}

type nostrClient struct {
	relays    []string
	filter    map[string]any
	events    chan nostrEvent
	onConnect func()

	mu    sync.Mutex
	conns map[string]*websocket.Conn
	seen  map[string]bool
	order []string
	ctx   context.Context
	stop  context.CancelFunc
}

func newNostrClient(relays []string, filter map[string]any) *nostrClient {
	ctx, cancel := context.WithCancel(context.Background())
	return &nostrClient{relays: relays, filter: filter, events: make(chan nostrEvent, 256),
		conns: map[string]*websocket.Conn{}, seen: map[string]bool{}, ctx: ctx, stop: cancel}
}

func (n *nostrClient) start() {
	for _, r := range n.relays {
		go n.run(r)
	}
}

func (n *nostrClient) connected() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.conns)
}

func (n *nostrClient) run(url string) {
	backoff := 2 * time.Second
	for n.ctx.Err() == nil {
		ctx, cancel := context.WithTimeout(n.ctx, 10*time.Second)
		c, _, err := websocket.Dial(ctx, url, nil)
		cancel()
		if err != nil {
			log.Printf("relay %s: could not connect: %v", url, err)
		} else {
			backoff = 2 * time.Second
			n.serve(url, c)
		}
		select {
		case <-n.ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < 5*time.Minute {
			backoff *= 2
		}
	}
}

func (n *nostrClient) serve(url string, c *websocket.Conn) {
	c.SetReadLimit(1 << 20)
	req, _ := json.Marshal([]any{"REQ", "gundil", n.filter})
	if err := c.Write(n.ctx, websocket.MessageText, req); err != nil {
		c.CloseNow()
		return
	}
	n.mu.Lock()
	n.conns[url] = c
	n.mu.Unlock()
	log.Printf("relay %s connected", url)
	if n.onConnect != nil {
		go n.onConnect()
	}
	pingCtx, stopPing := context.WithCancel(n.ctx)
	go func() {
		for {
			select {
			case <-pingCtx.Done():
				return
			case <-time.After(120 * time.Second):
				ctx, cancel := context.WithTimeout(pingCtx, 20*time.Second)
				if err := c.Ping(ctx); err != nil {
					c.CloseNow()
				}
				cancel()
			}
		}
	}()
	defer func() {
		stopPing()
		n.mu.Lock()
		delete(n.conns, url)
		n.mu.Unlock()
		c.CloseNow()
		if n.ctx.Err() == nil {
			log.Printf("relay %s disconnected", url)
		}
	}()
	for {
		_, data, err := c.Read(n.ctx)
		if err != nil {
			return
		}
		var msg []json.RawMessage
		if json.Unmarshal(data, &msg) != nil || len(msg) == 0 {
			continue
		}
		var kind string
		json.Unmarshal(msg[0], &kind)
		switch kind {
		case "EVENT":
			if len(msg) < 3 {
				continue
			}
			var e nostrEvent
			if json.Unmarshal(msg[2], &e) != nil {
				continue
			}
			n.mu.Lock()
			dup := n.seen[e.ID]
			if !dup {
				n.seen[e.ID] = true
				n.order = append(n.order, e.ID)
				if len(n.order) > 2000 {
					delete(n.seen, n.order[0])
					n.order = n.order[1:]
				}
			}
			n.mu.Unlock()
			if dup || !e.valid() {
				continue
			}
			select {
			case n.events <- e:
			case <-n.ctx.Done():
				return
			}
		case "NOTICE":
			if len(msg) >= 2 {
				log.Printf("relay %s: %s", url, strings.Trim(string(msg[1]), `"`))
			}
		}
	}
}

func (n *nostrClient) publish(e nostrEvent) int {
	msg, _ := json.Marshal([]any{"EVENT", e})
	n.mu.Lock()
	conns := make([]*websocket.Conn, 0, len(n.conns))
	for _, c := range n.conns {
		conns = append(conns, c)
	}
	n.mu.Unlock()
	sent := 0
	for _, c := range conns {
		ctx, cancel := context.WithTimeout(n.ctx, 5*time.Second)
		if c.Write(ctx, websocket.MessageText, msg) == nil {
			sent++
		}
		cancel()
	}
	return sent
}

func (n *nostrClient) close() { n.stop() }
