package main

// The home key: a random 256-bit key that replaces the intercom password
// for Internet calls when there is none (see the app's home_key.dart).

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
)

const pairPrefix = "GUNDIL-PAIR-"

var homeSalt = []byte("gundil-intercom/v1/home-key")

var hex64 = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

// parseHomeKey reads a pairing code (GUNDIL-PAIR-…) or 64 hex digits.
func parseHomeKey(text string) ([]byte, error) {
	t := strings.Join(strings.Fields(text), "")
	if hex64.MatchString(t) {
		return hex.DecodeString(t)
	}
	if !strings.HasPrefix(strings.ToUpper(t), pairPrefix) {
		return nil, errors.New("home_key is not a Gundil pairing code (it starts with " + pairPrefix + ")")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(t[len(pairPrefix):], "="))
	if err != nil || len(raw) != 35 {
		return nil, errors.New("home_key: the pairing code is damaged or incomplete")
	}
	key := raw[:32]
	sum := sha256.Sum256(key)
	if sum[0] != raw[32] || sum[1] != raw[33] || sum[2] != raw[34] {
		return nil, errors.New("home_key: the pairing code has a typo (check digits don't match)")
	}
	return key, nil
}

func pairingText(key []byte) string {
	sum := sha256.Sum256(key)
	raw := append(append([]byte{}, key...), sum[0], sum[1], sum[2])
	return pairPrefix + base64.RawURLEncoding.EncodeToString(raw)
}

func homeFingerprint(key []byte) string {
	h := strings.ToUpper(hex.EncodeToString(hkdfBytes(key, homeSalt, []byte("gundil/v1/fingerprint"), 4)))
	return h[:4] + "-" + h[4:]
}

func homeRendezvous(key []byte) rendezvousKeys {
	return rendezvousFromRoot(hkdfBytes(key, homeSalt, []byte("gundil/v1/internet"), 32))
}

func homeLinkSecret(key []byte) []byte {
	return hkdfBytes(key, homeSalt, []byte("gundil/v1/link"), 32)
}
