package main

// The same cryptography as the app (packages/intercom_core/lib/src/
// secure_channel.dart and internet/rendezvous.dart): X25519 + HKDF-SHA256 +
// ChaCha20-Poly1305 for links, scrypt for the meeting place on the relays.
// testdata/vectors.json, written by the Dart tests, keeps both in step.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
	"golang.org/x/crypto/pbkdf2"
	"golang.org/x/crypto/scrypt"
)

const (
	keyExchangeVersion = 1
	passwordIterations = 10000
	defaultScryptN     = 1 << 15
)

func hkdfBytes(ikm, salt, info []byte, n int) []byte {
	out := make([]byte, n)
	if _, err := io.ReadFull(hkdf.New(sha256.New, ikm, salt, info), out); err != nil {
		panic(err)
	}
	return out
}

// networkSecret turns the intercom password into the secret mixed into
// every key exchange.
func networkSecret(password string) []byte {
	if password == "" {
		s := sha256.Sum256([]byte("gundil-intercom/v4/no-password"))
		return s[:]
	}
	return pbkdf2.Key([]byte(password), []byte("gundil-intercom/v4/password"),
		passwordIterations, 32, sha256.New)
}

type keyPair struct{ priv, pub []byte }

func newKeyPair() keyPair {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		panic(err)
	}
	return keyPairFrom(priv)
}

func keyPairFrom(priv []byte) keyPair {
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		panic(err)
	}
	return keyPair{priv, pub}
}

type sessionKeys struct {
	send, receive []byte
	code          string
}

func deriveSession(mine keyPair, theirs, secret []byte) (sessionKeys, error) {
	if len(theirs) != 32 {
		return sessionKeys{}, errors.New("bad public key")
	}
	shared, err := curve25519.X25519(mine.priv, theirs)
	if err != nil {
		return sessionKeys{}, err // All-zero (weak) key.
	}
	order := compare(mine.pub, theirs)
	if order == 0 {
		return sessionKeys{}, errors.New("own key echoed")
	}
	low, high := mine.pub, theirs
	if order > 0 {
		low, high = theirs, mine.pub
	}
	info := append(append([]byte("gundil-intercom/v4/session"), low...), high...)
	okm := hkdfBytes(shared, secret, info, 68)
	lowKey, highKey := okm[:32], okm[32:64]
	c := binary.BigEndian.Uint32(okm[64:68]) % 1000000
	code := fmt.Sprintf("%06d", c)
	k := sessionKeys{code: code[:3] + " " + code[3:]}
	if order < 0 {
		k.send, k.receive = lowKey, highKey
	} else {
		k.send, k.receive = highKey, lowKey
	}
	return k, nil
}

func compare(a, b []byte) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		if a[i] != b[i] {
			return int(a[i]) - int(b[i])
		}
	}
	return len(a) - len(b)
}

// frameCipher seals one direction of a link; the nonce is a frame counter.
type frameCipher struct {
	key     []byte
	counter uint64
}

func (f *frameCipher) nonce() []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint64(n[4:], f.counter)
	f.counter++
	return n
}

func (f *frameCipher) seal(typ byte, payload []byte) []byte {
	aead, _ := chacha20poly1305.New(f.key)
	plain := append([]byte{typ}, payload...)
	return aead.Seal(nil, f.nonce(), plain, nil)
}

func (f *frameCipher) open(sealed []byte) (byte, []byte, error) {
	if len(sealed) < 17 {
		return 0, nil, errors.New("sealed frame too short")
	}
	aead, _ := chacha20poly1305.New(f.key)
	plain, err := aead.Open(nil, f.nonce(), sealed, nil)
	if err != nil {
		return 0, nil, err
	}
	return plain[0], plain[1:], nil
}

// sealMessage: nonce(12) || ChaCha20-Poly1305, for messages on the relays.
func sealMessage(key, plain []byte) []byte {
	aead, _ := chacha20poly1305.New(key)
	nonce := make([]byte, 12)
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	return aead.Seal(nonce, nonce, plain, nil)
}

func openMessage(key, data []byte) ([]byte, error) {
	if len(data) < 28 {
		return nil, errors.New("message too short")
	}
	aead, _ := chacha20poly1305.New(key)
	return aead.Open(nil, data[:12], data[12:], nil)
}

type rendezvousKeys struct {
	topic      string
	contentKey []byte
}

func deriveRendezvous(password string, n int) rendezvousKeys {
	key, err := scrypt.Key([]byte(password), []byte("gundil-intercom/v1/internet"), n, 8, 1, 32)
	if err != nil {
		panic(err)
	}
	return rendezvousKeys{
		topic:      fmt.Sprintf("%x", hkdfBytes(key, nil, []byte("gundil/v1/topic"), 16)),
		contentKey: hkdfBytes(key, nil, []byte("gundil/v1/content"), 32),
	}
}

// punchKeys: the link id and the punch key for signal [sid].
func punchKeys(contentKey []byte, sid string) (uint32, []byte) {
	k := hkdfBytes(contentKey, nil, []byte("gundil/v1/punch/"+sid), 36)
	return binary.BigEndian.Uint32(k[32:36]), k[:32]
}

func punchMAC(key []byte, kind byte, connID uint32) []byte {
	m := hmac.New(sha256.New, key)
	msg := make([]byte, 5)
	msg[0] = kind
	binary.BigEndian.PutUint32(msg[1:], connID)
	m.Write(msg)
	return m.Sum(nil)[:16]
}
