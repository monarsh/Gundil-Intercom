package main

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

type vectors struct {
	Password         string `json:"password"`
	NetworkSecret    string `json:"networkSecret"`
	NoPasswordSecret string `json:"noPasswordSecret"`
	PrivA, PubA      string
	PrivB, PubB      string
	SendKeyA         string `json:"sendKeyA"`
	ReceiveKeyA      string `json:"receiveKeyA"`
	SecurityCode     string `json:"securityCode"`
	SealedHelloA0    string `json:"sealedHelloA0"`
	ScryptN          int    `json:"scryptN"`
	Topic            string `json:"topic"`
	ContentKey       string `json:"contentKey"`
	PunchSid         string `json:"punchSid"`
	PunchKey         string `json:"punchKey"`
	PunchConnID      uint32 `json:"punchConnId"`
}

func h(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func TestVectorsMatchTheApp(t *testing.T) {
	raw, err := os.ReadFile("testdata/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	x := func(name string, got []byte, want string) {
		if hex.EncodeToString(got) != want {
			t.Errorf("%s: got %x, want %s", name, got, want)
		}
	}
	secret := networkSecret(v.Password)
	x("networkSecret", secret, v.NetworkSecret)
	x("noPasswordSecret", networkSecret(""), v.NoPasswordSecret)
	a := keyPairFrom(h(v.PrivA))
	b := keyPairFrom(h(v.PrivB))
	x("pubA", a.pub, v.PubA)
	x("pubB", b.pub, v.PubB)
	ka, err := deriveSession(a, b.pub, secret)
	if err != nil {
		t.Fatal(err)
	}
	x("sendKeyA", ka.send, v.SendKeyA)
	x("receiveKeyA", ka.receive, v.ReceiveKeyA)
	if ka.code != v.SecurityCode {
		t.Errorf("code %q, want %q", ka.code, v.SecurityCode)
	}
	fc := frameCipher{key: ka.send}
	x("sealedHelloA0", fc.seal(tHello, []byte(`{"id":"x"}`)), v.SealedHelloA0)
	// B opens what A sealed.
	kb, _ := deriveSession(b, a.pub, secret)
	op := frameCipher{key: kb.receive}
	typ, p, err := op.open(h(v.SealedHelloA0))
	if err != nil || typ != tHello || string(p) != `{"id":"x"}` {
		t.Errorf("open: %v %d %q", err, typ, p)
	}
	rv := deriveRendezvous(v.Password, v.ScryptN)
	if rv.topic != v.Topic {
		t.Errorf("topic %s, want %s", rv.topic, v.Topic)
	}
	x("contentKey", rv.contentKey, v.ContentKey)
	id, key := punchKeys(rv.contentKey, v.PunchSid)
	x("punchKey", key, v.PunchKey)
	if id != v.PunchConnID {
		t.Errorf("connId %d, want %d", id, v.PunchConnID)
	}
}
