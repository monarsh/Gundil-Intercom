package main

// Self-update protocol, shared by gundil-update-server and the update
// clients (the app's update_client.dart, and this gateway's updater):
//
//   - The server has a static X25519 key. Its public half, written as a
//     "server code" (GUNDIL-UPDATE-...), is built into the apps.
//   - It listens on the Nostr relays under a topic derived from that key.
//     A device sends an offer there: its ephemeral public key in clear, and
//     its candidates sealed with a key from X25519(ephemeral, server key).
//     Only the server can read it and answer, so a link that completes the
//     key exchange with that secret is the server.
//   - Both punch (the usual UDP link), exchange keys with the link secret,
//     then: CHECK (device) → INFO (server) → GET → DATA… → END.

import (
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Frame types on an update link (packages/intercom_core/lib/src/protocol.dart).
const (
	tUpdCheck = 0x30 // device → server: {"id","name","package","version","os"}
	tUpdInfo  = 0x31 // server → device: {"mode","target":{...},"message"}
	tUpdGet   = 0x32 // device → server: {"file","offset"}
	tUpdData  = 0x33 // server → device: [offset:8][bytes]
	tUpdEnd   = 0x34 // server → device: {"ok","error"}
)

const updateCodePrefix = "GUNDIL-UPDATE-"

// updateCodeText writes the server's public key as a server code.
func updateCodeText(pub []byte) string {
	sum := sha256.Sum256(pub)
	return updateCodePrefix + base64.RawURLEncoding.EncodeToString(append(append([]byte{}, pub...), sum[:3]...))
}

// parseUpdateCode reads a server code back into the server's public key.
func parseUpdateCode(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(strings.ToUpper(s), updateCodePrefix) {
		return nil, errors.New("not an update server code (it starts with GUNDIL-UPDATE-)")
	}
	b, err := base64.RawURLEncoding.DecodeString(s[len(updateCodePrefix):])
	if err != nil || len(b) != 35 {
		return nil, errors.New("the update server code is incomplete")
	}
	sum := sha256.Sum256(b[:32])
	if sum[0] != b[32] || sum[1] != b[33] || sum[2] != b[34] {
		return nil, errors.New("the update server code has a typo")
	}
	return b[:32], nil
}

// updateTopic: where the server listens on the relays (public).
func updateTopic(serverPub []byte) string {
	return fmt.Sprintf("%x", hkdfBytes(serverPub, nil, []byte("gundil/v1/update/topic"), 16))
}

// updateSessionKeys: the content key (offer/answer, punch keys) and the
// link secret, from X25519(ephemeral, server).
func updateSessionKeys(shared, devicePub, serverPub []byte) (content, link []byte) {
	info := append(append([]byte{}, devicePub...), serverPub...)
	root := hkdfBytes(shared, []byte("gundil-update/v1"), info, 32)
	return hkdfBytes(root, nil, []byte("gundil/v1/update/content"), 32),
		hkdfBytes(root, nil, []byte("gundil/v1/update/link"), 32)
}

// ---------------------------------------------------------------- versions

// compareVersions compares "1.9.1"-style versions (a leading v is ignored).
func compareVersions(a, b string) int {
	pa, pb := versionParts(a), versionParts(b)
	for i := 0; i < 3; i++ {
		if pa[i] != pb[i] {
			if pa[i] < pb[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}

func versionParts(v string) [3]int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	var out [3]int
	for i, p := range strings.SplitN(v, ".", 3) {
		out[i], _ = strconv.Atoi(p)
	}
	return out
}

var versionRe = regexp.MustCompile(`^v?\d+\.\d+\.\d+$`)

func validVersion(v string) bool { return versionRe.MatchString(v) }

// ---------------------------------------------------------------- packages

// A package is what one installed copy is: its family (what the admin sets a
// version for) and the release file that updates it.
//
// Release files may carry an "app-" or "server-" prefix (1.9.1 and later);
// it's ignored when matching.
type packageKind struct {
	family  string
	pattern string // %s = version
}

var packageKinds = map[string]packageKind{
	"android-arm64-v8a":      {"android", "Gundil_Intercom-%s-android-arm64-v8a.apk"},
	"android-armeabi-v7a":    {"android", "Gundil_Intercom-%s-android-armeabi-v7a.apk"},
	"android-x86_64":         {"android", "Gundil_Intercom-%s-android-x86_64.apk"},
	"android-universal":      {"android", "Gundil_Intercom-%s-android-universal.apk"},
	"windows-x64-setup":      {"windows", "Gundil_Intercom-%s-windows-x64-setup.exe"},
	"windows-x64-portable":   {"windows", "Gundil_Intercom-%s-windows-x64-portable.zip"},
	"macos":                  {"macos", "Gundil_Intercom-%s-macos.zip"},
	"ios":                    {"ios", "Gundil_Intercom-%s-ios-unsigned.ipa"},
	"appimage-x86_64":        {"linux", "gundil-intercom-%s-x86_64.AppImage"},
	"appimage-aarch64":       {"linux", "gundil-intercom-%s-aarch64.AppImage"},
	"linux-x64":              {"linux", "gundil-intercom-%s-linux-x64.tar.gz"},
	"linux-arm64":            {"linux", "gundil-intercom-%s-linux-arm64.tar.gz"},
	"node-arm":               {"node", "gundil-intercom-node-%s-linux-arm.tar.gz"},
	"node-arm64":             {"node", "gundil-intercom-node-%s-linux-arm64.tar.gz"},
	"gateway-linux-x86_64":   {"gateway", "gundil-gateway-%s-linux-x86_64.tar.gz"},
	"gateway-linux-arm64":    {"gateway", "gundil-gateway-%s-linux-arm64.tar.gz"},
	"gateway-linux-armv7":    {"gateway", "gundil-gateway-%s-linux-armv7.tar.gz"},
	"gateway-linux-armv6":    {"gateway", "gundil-gateway-%s-linux-armv6.tar.gz"},
	"gateway-linux-mips":     {"gateway", "gundil-gateway-%s-linux-mips.tar.gz"},
	"gateway-linux-mipsle":   {"gateway", "gundil-gateway-%s-linux-mipsle.tar.gz"},
	"gateway-windows-x86_64": {"gateway", "gundil-gateway-%s-windows-x86_64.zip"},
	"gateway-windows-arm64":  {"gateway", "gundil-gateway-%s-windows-arm64.zip"},
}

// families, in the order the web page shows them.
var families = []struct{ ID, Name string }{
	{"android", "Android"},
	{"windows", "Windows"},
	{"macos", "Mac"},
	{"ios", "iPhone / iPad"},
	{"linux", "Linux desktop (AppImage, tar.gz)"},
	{"node", "Headless node (Raspberry Pi, Orange Pi)"},
	{"gateway", "gundil-gateway (router, Pi, server)"},
}

func familyOf(pkg string) string { return packageKinds[pkg].family }

// stripPrefix: the release file name without its app-/server- prefix.
func stripPrefix(name string) string {
	for _, p := range []string{"app-", "server-"} {
		if strings.HasPrefix(name, p) {
			return name[len(p):]
		}
	}
	return name
}

// packageOf: which package a release file updates, and its version
// ("", "" for files that update nothing, e.g. the server itself).
func packageOf(name string) (pkg, version string) {
	name = stripPrefix(name)
	for p, k := range packageKinds {
		pre, post, _ := strings.Cut(k.pattern, "%s")
		if strings.HasPrefix(name, pre) && strings.HasSuffix(name, post) && len(name) > len(pre)+len(post) {
			v := name[len(pre) : len(name)-len(post)]
			if validVersion(v) {
				return p, v
			}
		}
	}
	return "", ""
}
