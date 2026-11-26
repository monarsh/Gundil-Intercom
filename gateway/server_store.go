//go:build updateserver

package main

// What the update server keeps, as JSON files in its data directory:
//   keys.json      its X25519 key (the server code) and Nostr key
//   admin.json     the admin password hash, and whether it must be changed
//   devices.json   every device that checked in
//   policy.json    the version and mode per family
//   versions.json  the versions it offers, and their files
//   files/<version>/<name>  copies kept on this server

import (
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

type serverKeys struct {
	ServerKey string `json:"serverKey"`
	NostrKey  string `json:"nostrKey"`
}

type device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Package   string    `json:"package"`
	Version   string    `json:"version"`
	OS        string    `json:"os"`
	Address   string    `json:"address"`
	FirstSeen time.Time `json:"firstSeen"`
	LastSeen  time.Time `json:"lastSeen"`
	Pin       string    `json:"pin,omitempty"`     // A version just for this device.
	Offered   string    `json:"offered,omitempty"` // What it was told last.
	Fetched   string    `json:"fetched,omitempty"` // The last file it downloaded from here.
}

// familyPolicy: Target is "", "latest" or a version; Mode is "off", "ask"
// or "auto".
type familyPolicy struct {
	Target string `json:"target"`
	Mode   string `json:"mode"`
}

// defaultPolicy for a kind of device the admin hasn't set: offer the
// newest version, and let people choose (Ask) rather than install by
// itself everywhere.
var defaultPolicy = familyPolicy{Target: "latest", Mode: "ask"}

type versionFile struct {
	Name    string `json:"name"`  // Without the app-/server- prefix.
	Asset   string `json:"asset"` // As in the release.
	Package string `json:"package"`
	Size    int64  `json:"size"`
	SHA256  string `json:"sha256"`
	URL     string `json:"url,omitempty"` // GitHub download, when known.
	Local   bool   `json:"local"`         // A copy is in files/.
}

type versionEntry struct {
	Version string        `json:"version"`
	Source  string        `json:"source"` // "github" or "upload"
	Added   time.Time     `json:"added"`
	Notes   string        `json:"notes,omitempty"`
	Files   []versionFile `json:"files"`
	Sums    string        `json:"sums,omitempty"` // The release's SHA256SUMS.txt…
	Sig     string        `json:"sig,omitempty"`  // …and its signature (base64; release_sig.go).
}

type store struct {
	dir string
	mu  sync.Mutex

	keys     serverKeys
	admin    *adminAccount
	devices  map[string]*device
	policy   map[string]familyPolicy
	versions []*versionEntry

	devicesDirty bool
}

func openStore(dir string) (*store, error) {
	if err := os.MkdirAll(filepath.Join(dir, "files"), 0o700); err != nil {
		return nil, err
	}
	s := &store{dir: dir, devices: map[string]*device{}, policy: map[string]familyPolicy{}}
	readJSON(s.path("keys.json"), &s.keys)
	if len(s.keys.ServerKey) != 64 || len(s.keys.NostrKey) != 64 {
		s.keys = serverKeys{ServerKey: randomHex(32), NostrKey: randomHex(32)}
		if err := writeJSON(s.path("keys.json"), s.keys); err != nil {
			return nil, err
		}
	}
	var a adminAccount
	if readJSON(s.path("admin.json"), &a) == nil && a.Hash != "" {
		s.admin = &a
	}
	var devs []*device
	readJSON(s.path("devices.json"), &devs)
	for _, d := range devs {
		s.devices[d.ID] = d
	}
	readJSON(s.path("policy.json"), &s.policy)
	readJSON(s.path("versions.json"), &s.versions)
	s.sortVersions()
	go func() { // Device check-ins are saved at most every 30 s (flash).
		for range time.Tick(30 * time.Second) {
			s.flushDevices()
		}
	}()
	return s, nil
}

func (s *store) path(name string) string { return filepath.Join(s.dir, name) }

func (s *store) filePath(version, name string) string {
	return filepath.Join(s.dir, "files", version, filepath.Base(name))
}

func (s *store) serverKey() keyPair {
	b, _ := hex.DecodeString(s.keys.ServerKey)
	return keyPairFrom(b)
}

// ------------------------------------------------------------------ admin

func (s *store) adminAccount() *adminAccount {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.admin == nil {
		return nil
	}
	a := *s.admin
	return &a
}

func (s *store) setAdmin(a *adminAccount) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := writeJSON(s.path("admin.json"), a); err != nil {
		return err
	}
	s.admin = a
	return nil
}

// ---------------------------------------------------------------- devices

func (s *store) checkIn(d device) *device {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur := s.devices[d.ID]
	if cur == nil {
		cur = &device{ID: d.ID, FirstSeen: time.Now()}
		s.devices[d.ID] = cur
	}
	cur.Name, cur.Package, cur.Version, cur.OS, cur.Address = d.Name, d.Package, d.Version, d.OS, d.Address
	cur.LastSeen = time.Now()
	s.devicesDirty = true
	c := *cur
	return &c
}

func (s *store) updateDevice(id string, f func(d *device)) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.devices[id]
	if d == nil {
		return false
	}
	f(d)
	s.devicesDirty = true
	return true
}

func (s *store) deleteDevice(id string) {
	s.mu.Lock()
	delete(s.devices, id)
	s.devicesDirty = true
	s.mu.Unlock()
	s.flushDevices()
}

func (s *store) deviceList() []device {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]device, 0, len(s.devices))
	for _, d := range s.devices {
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastSeen.After(out[j].LastSeen) })
	return out
}

func (s *store) flushDevices() {
	s.mu.Lock()
	if !s.devicesDirty {
		s.mu.Unlock()
		return
	}
	list := make([]*device, 0, len(s.devices))
	for _, d := range s.devices {
		c := *d
		list = append(list, &c)
	}
	s.devicesDirty = false
	s.mu.Unlock()
	writeJSON(s.path("devices.json"), list)
}

// ----------------------------------------------------------------- policy

func (s *store) policyFor(family string) familyPolicy {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.policy[family]
	if !ok {
		return defaultPolicy
	}
	return p
}

func (s *store) allPolicy() map[string]familyPolicy {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]familyPolicy{}
	for _, f := range families {
		p, ok := s.policy[f.ID]
		if !ok {
			p = defaultPolicy
		}
		out[f.ID] = p
	}
	return out
}

func (s *store) setPolicy(p map[string]familyPolicy) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, v := range p {
		s.policy[k] = v
	}
	return writeJSON(s.path("policy.json"), s.policy)
}

// --------------------------------------------------------------- versions

func (s *store) sortVersions() {
	sort.Slice(s.versions, func(i, j int) bool {
		return compareVersions(s.versions[i].Version, s.versions[j].Version) > 0
	})
}

func (s *store) versionList() []versionEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]versionEntry, len(s.versions))
	for i, v := range s.versions {
		out[i] = *v
		out[i].Files = append([]versionFile(nil), v.Files...)
	}
	return out
}

func (s *store) findVersion(v string) *versionEntry {
	for _, e := range s.versions {
		if compareVersions(e.Version, v) == 0 {
			return e
		}
	}
	return nil
}

// addFiles adds (or replaces) files of a version.
func (s *store) addFiles(version, source, notes string, files []versionFile) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := s.findVersion(version)
	if e == nil {
		e = &versionEntry{Version: version, Source: source, Added: time.Now(), Notes: notes}
		s.versions = append(s.versions, e)
		s.sortVersions()
	}
	if notes != "" {
		e.Notes = notes
	}
	for _, f := range files {
		replaced := false
		for i := range e.Files {
			if e.Files[i].Name == f.Name {
				e.Files[i], replaced = f, true
			}
		}
		if !replaced {
			e.Files = append(e.Files, f)
		}
	}
	sort.Slice(e.Files, func(i, j int) bool { return e.Files[i].Name < e.Files[j].Name })
	return writeJSON(s.path("versions.json"), s.versions)
}

func (s *store) deleteVersion(version string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, e := range s.versions {
		if compareVersions(e.Version, version) == 0 {
			s.versions = append(s.versions[:i], s.versions[i+1:]...)
			os.RemoveAll(filepath.Join(s.dir, "files", e.Version))
			return writeJSON(s.path("versions.json"), s.versions)
		}
	}
	return errors.New("no such version")
}

// fileFor: the release file of [version] for [pkg].
func (s *store) fileFor(version, pkg string) *versionFile {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := s.findVersion(version)
	if e == nil {
		return nil
	}
	for _, f := range e.Files {
		if f.Package == pkg {
			c := f
			return &c
		}
	}
	return nil
}

// latestFor: the newest version that has a file for [pkg].
func (s *store) latestFor(pkg string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, e := range s.versions {
		for _, f := range e.Files {
			if f.Package == pkg {
				return e.Version
			}
		}
	}
	return ""
}

// localFile: the path of a kept copy, by its stripped name.
func (s *store) localFile(name string) (string, *versionFile) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, e := range s.versions {
		for _, f := range e.Files {
			if f.Name == name && f.Local {
				c := f
				return s.filePath(e.Version, f.Name), &c
			}
		}
	}
	return "", nil
}

// setSignature stores a release's signed SHA256SUMS.txt for [version].
func (s *store) setSignature(version, sums, sig string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := s.findVersion(version)
	if e == nil {
		return errors.New("no such version")
	}
	e.Sums, e.Sig = sums, sig
	return writeJSON(s.path("versions.json"), s.versions)
}

// signatureOf: [version]'s signed SHA256SUMS.txt, if any.
func (s *store) signatureOf(version string) (sums, sig string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e := s.findVersion(version); e != nil {
		return e.Sums, e.Sig
	}
	return "", ""
}

// unsignedGithubVersions: versions from GitHub without a signature (added
// before the releases were signed, or by an older server).
func (s *store) unsignedGithubVersions() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for _, e := range s.versions {
		if e.Source == "github" && e.Sig == "" {
			out = append(out, e.Version)
		}
	}
	return out
}
