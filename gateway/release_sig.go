package main

// Signed releases. The release build signs the release's SHA256SUMS.txt
// with a P-256 key that only GitHub holds (secret GUNDIL_RELEASE_SIGNING_KEY)
// and attaches SHA256SUMS.txt.sig. Builds carry the public half
// (repository variable GUNDIL_RELEASE_KEY → releaseKey). An update is
// installed only when the signature is good and the file's SHA-256 is the
// one in the signed list, so an update server (even a stolen one) can only
// offer files from real releases. Builds without a key don't check (forks,
// development builds).
//
// The same check is in packages/intercom_core/lib/src/update/release_signature.dart.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"math/big"
	"strings"
)

// releaseKey: base64 of the uncompressed P-256 public key (65 bytes,
// 04||X||Y); set at build time (-X main.releaseKey=…).
var releaseKey = ""

func parseReleaseKey(s string) (*ecdsa.PublicKey, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil || len(b) != 65 || b[0] != 4 {
		return nil, errors.New("the release key is not a P-256 public key (65 bytes, base64)")
	}
	k := &ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(b[1:33]), Y: new(big.Int).SetBytes(b[33:])}
	if !k.Curve.IsOnCurve(k.X, k.Y) {
		return nil, errors.New("the release key is not on the P-256 curve")
	}
	return k, nil
}

// sumsLookup: the SHA-256 of [name] in a sha256sum list ("<hex>  <name>").
func sumsLookup(sums, name string) string {
	for _, line := range strings.Split(sums, "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == name {
			return strings.ToLower(f[0])
		}
	}
	return ""
}

// verifyRelease checks an offered file against the signed list: [key] is
// the release key (base64; empty: no check), [sums] the release's
// SHA256SUMS.txt, [sig] its signature (base64 DER), [asset] the file's name
// in the release and [sha] the SHA-256 the server offers.
func verifyRelease(key, sums, sig, asset, sha string) error {
	if strings.TrimSpace(key) == "" {
		return nil
	}
	pub, err := parseReleaseKey(key)
	if err != nil {
		return err
	}
	if sums == "" || sig == "" {
		return errors.New("the release is not signed (the update server has no signature for it: add the release again)")
	}
	if err := verifySums(pub, sums, sig); err != nil {
		return err
	}
	want := sumsLookup(sums, asset)
	if want == "" {
		return fmt.Errorf("%s is not in the signed release", asset)
	}
	if want != strings.ToLower(sha) {
		return fmt.Errorf("%s is not the file of the signed release (SHA-256)", asset)
	}
	return nil
}

// verifySums checks the signature of a release's SHA256SUMS.txt.
func verifySums(pub *ecdsa.PublicKey, sums, sig string) error {
	der, err := base64.StdEncoding.DecodeString(strings.TrimSpace(sig))
	if err != nil {
		return errors.New("the release signature is not base64")
	}
	h := sha256.Sum256([]byte(sums))
	if !ecdsa.VerifyASN1(pub, h[:], der) {
		return errors.New("the release is not signed by the Gundil release key")
	}
	return nil
}

// sumsAsset: [file]'s name as listed in [sums]: as uploaded, or with the
// release's app-/server- prefix.
func sumsAsset(sums, asset, file string) string {
	for _, n := range []string{asset, "app-" + file, "server-" + file, file} {
		if n != "" && sumsLookup(sums, n) != "" {
			return n
		}
	}
	return asset
}
