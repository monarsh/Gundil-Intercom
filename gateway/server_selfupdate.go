//go:build updateserver

package main

// Updating the update server itself from the GitHub releases (Server tab →
// Update): the newest release with this platform's server file; its
// SHA-256 must be the one in the release's signed SHA256SUMS.txt (builds
// with the release key) or at least in SHA256SUMS.txt / GitHub's digest.
// The program (and the web page next to it) is replaced and restarted.

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"
)

// serverAsset: the end of this platform's release file name, e.g.
// "linux-arm64.tar.gz"; "" when there is none.
func serverAsset() string {
	if os.Getenv("APPIMAGE") != "" {
		switch runtime.GOARCH {
		case "amd64":
			return "x86_64.AppImage"
		case "arm64":
			return "aarch64.AppImage"
		}
		return ""
	}
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "linux/amd64":
		return "linux-x86_64.tar.gz"
	case "linux/arm64":
		return "linux-arm64.tar.gz"
	case "linux/arm":
		if bi, ok := debug.ReadBuildInfo(); ok {
			for _, s := range bi.Settings {
				if s.Key == "GOARM" && (strings.HasPrefix(s.Value, "6") || strings.HasPrefix(s.Value, "5")) {
					return "linux-armv6.tar.gz"
				}
			}
		}
		return "linux-armv7.tar.gz"
	case "linux/mips":
		return "linux-mips.tar.gz"
	case "linux/mipsle":
		return "linux-mipsle.tar.gz"
	case "windows/amd64":
		return "windows-x86_64.zip"
	case "windows/arm64":
		return "windows-arm64.zip"
	}
	return ""
}

// selfUpdater: the state the Server tab shows.
type selfUpdater struct {
	repo   string
	webDir string

	run sync.Mutex // One check or install at a time.
	mu  sync.Mutex
	st  selfStatus
	rel *ghRelease
	ast ghAsset

	// Replaced in tests.
	releases     func(repo string) ([]ghRelease, error)
	sums         func(r ghRelease) (sums, sig string)
	exe          func() (string, error)
	afterInstall func(exe string)
}

type selfStatus struct {
	Version   string    `json:"version"`
	Latest    string    `json:"latest"`    // The newest release with this platform's file.
	Available bool      `json:"available"` // Newer than this one.
	Notes     string    `json:"notes"`     // Its release notes.
	LastCheck time.Time `json:"lastCheck"`
	Result    string    `json:"result"`
	Busy      string    `json:"busy"` // "checking", "installing" or "".
	Problem   string    `json:"problem"`
}

func newSelfUpdater(repo, webDir string) *selfUpdater {
	u := &selfUpdater{repo: repo, webDir: webDir, releases: githubReleases, sums: releaseSums,
		exe: serverExe, afterInstall: restartSelf}
	u.st.Version = version
	if serverAsset() == "" {
		u.st.Problem = fmt.Sprintf("No server file for %s/%s in the releases: update it by hand.", runtime.GOOS, runtime.GOARCH)
	}
	return u
}

// serverExe: the file to replace (the AppImage itself when run from one).
func serverExe() (string, error) {
	if p := os.Getenv("APPIMAGE"); p != "" {
		return p, nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

func (u *selfUpdater) status() selfStatus {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.st
}

func (u *selfUpdater) set(f func(s *selfStatus)) {
	u.mu.Lock()
	f(&u.st)
	u.mu.Unlock()
}

// runChecks: a look at GitHub a minute after start and once a day, so the
// page and the log say when a new version is out. Never installs by itself.
func (u *selfUpdater) runChecks() {
	time.Sleep(time.Minute)
	for {
		if err := u.check(); err != nil {
			log.Printf("server update: %v", err)
		} else if s := u.status(); s.Available {
			log.Printf("server update: version %s is out (this is %s): Server tab → Update", s.Latest, version)
		}
		time.Sleep(24 * time.Hour)
	}
}

// check finds the newest release with this platform's server file.
func (u *selfUpdater) check() (err error) {
	u.run.Lock()
	defer u.run.Unlock()
	return u.checkLocked()
}

func (u *selfUpdater) checkLocked() (err error) {
	u.set(func(s *selfStatus) { s.Busy = "checking" })
	defer func() {
		u.set(func(s *selfStatus) {
			s.Busy, s.LastCheck = "", time.Now()
			if err != nil {
				s.Result = err.Error()
			}
		})
	}()
	suffix := serverAsset()
	if suffix == "" {
		return errors.New(u.status().Problem)
	}
	rels, err := u.releases(u.repo)
	if err != nil {
		return fmt.Errorf("could not read the releases from GitHub: %v", err)
	}
	var best *ghRelease
	var bestAsset ghAsset
	for i := range rels {
		r := &rels[i]
		if r.Draft || r.Prerelease || !validVersion(r.Tag) {
			continue
		}
		want := "gundil-update-server-" + strings.TrimPrefix(r.Tag, "v") + "-" + suffix
		for _, a := range r.Assets {
			if stripPrefix(a.Name) == want && (best == nil || compareVersions(r.Tag, best.Tag) > 0) {
				best, bestAsset = r, a
			}
		}
	}
	if best == nil {
		return fmt.Errorf("no release on GitHub (%s) has a server file for this platform (%s)", u.repo, suffix)
	}
	latest := strings.TrimPrefix(best.Tag, "v")
	// A test build (1.12.0-test.1) is older than its release (1.12.0).
	cmp := compareVersions(latest, version)
	newer := cmp > 0 || (cmp == 0 && strings.Contains(version, "-"))
	u.mu.Lock()
	u.rel, u.ast = best, bestAsset
	u.st.Latest, u.st.Available, u.st.Notes = latest, newer, best.Body
	if newer {
		u.st.Result = "Version " + latest + " is available."
	} else {
		u.st.Result = "Up to date (" + version + ")."
	}
	u.mu.Unlock()
	return nil
}

// install downloads, checks and installs the newest release; true when the
// new program is in place (the caller restarts).
func (u *selfUpdater) install() (installed bool, err error) {
	u.run.Lock()
	defer u.run.Unlock()
	if err := u.checkLocked(); err != nil {
		return false, err
	}
	u.mu.Lock()
	rel, ast, newer := u.rel, u.ast, u.st.Available
	u.mu.Unlock()
	if !newer {
		return false, nil
	}
	u.set(func(s *selfStatus) { s.Busy = "installing" })
	defer func() {
		u.set(func(s *selfStatus) {
			s.Busy = ""
			if err != nil {
				s.Result = "Not installed: " + err.Error()
			}
		})
	}()
	exe, err := u.exe()
	if err != nil {
		return false, err
	}
	if err := canReplace(exe); err != nil {
		return false, fmt.Errorf("this server can't replace its own program (%v). Install the new version by hand once (Linux: run install.sh or deploy.sh of the new version); from then on Update works", err)
	}
	ver := strings.TrimPrefix(rel.Tag, "v")
	log.Printf("server update: installing %s (%s)", ver, ast.Name)
	dir, err := updateDir(exe, "gundil-server-update")
	if err != nil {
		return false, err
	}
	defer os.RemoveAll(dir)
	file := filepath.Join(dir, ast.Name)
	appImage := strings.HasSuffix(ast.Name, ".AppImage")
	if appImage {
		file = exe + ".new" // Renamed over the AppImage below: the same folder.
	}
	if err := fetchURL(ast.URL, file); err != nil {
		os.Remove(exe + ".new")
		return false, err
	}
	if err := u.verify(*rel, ast, file); err != nil {
		os.Remove(exe + ".new")
		return false, err
	}
	if appImage {
		err = replaceFile(file, exe)
	} else {
		// The web page first: a new program with the old page could break it.
		if err = u.installWeb(file); err == nil {
			err = installProgram(file, "gundil-update-server", exe)
		}
	}
	if err != nil {
		return false, err
	}
	log.Printf("server update: installed %s, restarting", ver)
	u.set(func(s *selfStatus) { s.Result = "Installed " + ver + "; restarting." })
	return true, nil
}

// verify: the file's SHA-256 against the release's (signed) list.
func (u *selfUpdater) verify(rel ghRelease, ast ghAsset, file string) error {
	sha, err := fileSHA256(file)
	if err != nil {
		return err
	}
	sums, sig := u.sums(rel)
	if releaseKey != "" {
		if err := verifyRelease(releaseKey, sums, sig, ast.Name, sha); err != nil {
			return fmt.Errorf("refused %s: %v", rel.Tag, err)
		}
		return nil
	}
	want := sumsLookup(sums, ast.Name)
	if want == "" {
		want = strings.ToLower(strings.TrimPrefix(ast.Digest, "sha256:"))
	}
	if want == "" {
		return errors.New("the release has no SHA-256 for the file: can't check it")
	}
	if want != sha {
		return errors.New("the downloaded file is damaged (SHA-256)")
	}
	return nil
}

// installWeb replaces the web page folder on disk (the program uses its
// built-in copy when there is none) with the one in [archive].
func (u *selfUpdater) installWeb(archive string) error {
	d := u.webDir
	if d == "" || !fileExists(filepath.Join(d, "index.html")) {
		return nil
	}
	staged, old := d+".new", d+".old"
	os.RemoveAll(staged)
	os.RemoveAll(old)
	n, err := extractDir(archive, "web", staged)
	if err == nil && n == 0 {
		err = errors.New("no web page in the update")
	}
	if err == nil {
		if err = os.Rename(d, old); err == nil {
			if err = os.Rename(staged, d); err != nil {
				os.Rename(old, d)
			}
		}
	}
	os.RemoveAll(staged)
	os.RemoveAll(old)
	if err != nil {
		return fmt.Errorf("could not replace the web page in %s: %v", d, err)
	}
	return nil
}
