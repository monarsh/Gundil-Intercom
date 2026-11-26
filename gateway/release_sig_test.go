package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

type sigVector struct {
	Key, Sums, Sig, Asset, SHA256 string
}

func loadSigVector(t *testing.T) sigVector {
	b, err := os.ReadFile("testdata/release_sig.json")
	if err != nil {
		t.Fatal(err)
	}
	var v sigVector
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// The fixture was signed with openssl, as the release build signs.
func TestVerifyRelease(t *testing.T) {
	v := loadSigVector(t)
	if err := verifyRelease(v.Key, v.Sums, v.Sig, v.Asset, v.SHA256); err != nil {
		t.Fatalf("good release refused: %v", err)
	}
	if err := verifyRelease(v.Key, v.Sums, v.Sig, v.Asset, strings.ToUpper(v.SHA256)); err != nil {
		t.Fatalf("upper-case SHA-256 refused: %v", err)
	}
	if err := verifyRelease("", "", "", v.Asset, "x"); err != nil {
		t.Fatalf("a build without a key must not check: %v", err)
	}
	other := strings.Repeat("0", 64)
	sig, _ := base64.StdEncoding.DecodeString(v.Sig)
	sig[len(sig)-1] ^= 1
	bad := map[string][5]string{
		"unsigned":         {v.Key, "", "", v.Asset, v.SHA256},
		"other file":       {v.Key, v.Sums, v.Sig, v.Asset, other},
		"not in the list":  {v.Key, v.Sums, v.Sig, "app-evil-9.9.9.tar.gz", v.SHA256},
		"list changed":     {v.Key, strings.Replace(v.Sums, v.SHA256, other, 1), v.Sig, v.Asset, other},
		"signature broken": {v.Key, v.Sums, base64.StdEncoding.EncodeToString(sig), v.Asset, v.SHA256},
		"bad key":          {"AAAA", v.Sums, v.Sig, v.Asset, v.SHA256},
	}
	for name, a := range bad {
		if err := verifyRelease(a[0], a[1], a[2], a[3], a[4]); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
