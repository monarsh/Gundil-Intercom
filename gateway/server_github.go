//go:build updateserver

package main

// Versions from the GitHub releases: the list, and importing one (its files'
// names, sizes, SHA-256 and download links; copies on request).

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var githubAPI = "https://api.github.com"

var httpClient = &http.Client{Timeout: 0} // Downloads can take long; requests use contexts below.

type ghAsset struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	URL    string `json:"browser_download_url"`
	Digest string `json:"digest"` // "sha256:…" (newer releases)
}

type ghRelease struct {
	Tag        string    `json:"tag_name"`
	Name       string    `json:"name"`
	Draft      bool      `json:"draft"`
	Prerelease bool      `json:"prerelease"`
	Published  time.Time `json:"published_at"`
	Body       string    `json:"body"`
	Assets     []ghAsset `json:"assets"`
}

func ghGet(url string, v any) error {
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "gundil-update-server")
	c := &http.Client{Timeout: 30 * time.Second}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("GitHub answered %s", resp.Status)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(v)
}

// githubReleases: the releases with files for the apps.
func githubReleases(repo string) ([]ghRelease, error) {
	var all []ghRelease
	if err := ghGet(fmt.Sprintf("%s/repos/%s/releases?per_page=50", githubAPI, repo), &all); err != nil {
		return nil, err
	}
	var out []ghRelease
	for _, r := range all {
		if r.Draft || !validVersion(r.Tag) {
			continue
		}
		for _, a := range r.Assets {
			if p, _ := packageOf(a.Name); p != "" {
				out = append(out, r)
				break
			}
		}
	}
	return out, nil
}

// sha256Sums reads a release's SHA256SUMS.txt (for files without a digest).
func sha256Sums(r ghRelease) map[string]string {
	out := map[string]string{}
	for _, a := range r.Assets {
		if a.Name != "SHA256SUMS.txt" && a.Name != "app-SHA256SUMS.txt" {
			continue
		}
		req, _ := http.NewRequest("GET", a.URL, nil)
		req.Header.Set("User-Agent", "gundil-update-server")
		resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(io.LimitReader(resp.Body, 1<<20))
		for sc.Scan() {
			f := strings.Fields(sc.Text())
			if len(f) == 2 && len(f[0]) == 64 {
				out[strings.TrimPrefix(f[1], "*")] = strings.ToLower(f[0])
			}
		}
		resp.Body.Close()
	}
	return out
}

// importJob: progress of copies being downloaded, for the web page.
type importJob struct {
	mu      sync.Mutex
	Version string `json:"version"`
	File    string `json:"file"`
	Done    int    `json:"done"`
	Total   int    `json:"total"`
	Bytes   int64  `json:"bytes"`
	Error   string `json:"error,omitempty"`
	Running bool   `json:"running"`
}

func (j *importJob) snapshot() map[string]any {
	j.mu.Lock()
	defer j.mu.Unlock()
	return map[string]any{"version": j.Version, "file": j.File, "done": j.Done, "total": j.Total,
		"bytes": j.Bytes, "error": j.Error, "running": j.Running}
}

func (j *importJob) set(f func(j *importJob)) {
	j.mu.Lock()
	f(j)
	j.mu.Unlock()
}

// importRelease adds a GitHub release's app files; with [keep], copies of
// the files of those families are downloaded to this server (in the
// background, reported by [job]).
func importRelease(st *store, repo, tag string, keep map[string]bool, job *importJob) error {
	rels, err := githubReleases(repo)
	if err != nil {
		return err
	}
	var rel *ghRelease
	for i := range rels {
		if rels[i].Tag == tag {
			rel = &rels[i]
		}
	}
	if rel == nil {
		return errors.New("no such release with app files")
	}
	version := strings.TrimPrefix(rel.Tag, "v")
	var sums map[string]string
	var files []versionFile
	for _, a := range rel.Assets {
		pkg, v := packageOf(a.Name)
		if pkg == "" || compareVersions(v, version) != 0 {
			continue
		}
		sum := strings.TrimPrefix(strings.ToLower(a.Digest), "sha256:")
		if len(sum) != 64 {
			if sums == nil {
				sums = sha256Sums(*rel)
			}
			sum = sums[a.Name]
		}
		if len(sum) != 64 {
			log.Printf("import %s: %s has no SHA-256, skipped", tag, a.Name)
			continue
		}
		files = append(files, versionFile{Name: stripPrefix(a.Name), Asset: a.Name, Package: pkg,
			Size: a.Size, SHA256: sum, URL: a.URL})
	}
	if len(files) == 0 {
		return errors.New("the release has no app files with a SHA-256")
	}
	notes := rel.Body
	if len(notes) > 20000 {
		notes = notes[:20000]
	}
	if err := st.addFiles(version, "github", notes, files); err != nil {
		return err
	}
	log.Printf("imported %s from GitHub: %d files", tag, len(files))
	var todo []versionFile
	for _, f := range files {
		if keep[familyOf(f.Package)] {
			todo = append(todo, f)
		}
	}
	if len(todo) > 0 {
		job.set(func(j *importJob) {
			*j = importJob{Version: version, Total: len(todo), Running: true}
		})
		go func() {
			for i, f := range todo {
				job.set(func(j *importJob) { j.File, j.Done, j.Bytes = f.Name, i, 0 })
				if err := download(st, version, f, job); err != nil {
					log.Printf("copy of %s failed: %v", f.Name, err)
					job.set(func(j *importJob) { j.Error = f.Name + ": " + err.Error() })
					continue
				}
				f.Local = true
				st.addFiles(version, "github", "", []versionFile{f})
			}
			job.set(func(j *importJob) { j.Done, j.Running, j.File = len(todo), false, "" })
		}()
	}
	return nil
}

// download copies a release file to files/, checking its SHA-256.
func download(st *store, version string, f versionFile, job *importJob) error {
	if f.URL == "" {
		return errors.New("no download link")
	}
	dst := st.filePath(version, f.Name)
	os.MkdirAll(filepath.Dir(dst), 0o700)
	req, _ := http.NewRequest("GET", f.URL, nil)
	req.Header.Set("User-Agent", "gundil-update-server")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download: %s", resp.Status)
	}
	return saveChecked(dst, resp.Body, f.SHA256, f.Size, func(n int64) {
		if job != nil {
			job.set(func(j *importJob) { j.Bytes = n })
		}
	})
}

// saveChecked writes [r] to [dst] (via a temporary file) and keeps it only
// when the SHA-256 (and size, when known) match.
func saveChecked(dst string, r io.Reader, sum string, size int64, progress func(int64)) error {
	tmp := dst + ".part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	h := sha256.New()
	var n int64
	buf := make([]byte, 64*1024)
	for {
		k, rerr := r.Read(buf)
		if k > 0 {
			if _, err := out.Write(buf[:k]); err != nil {
				out.Close()
				os.Remove(tmp)
				return err
			}
			h.Write(buf[:k])
			n += int64(k)
			if progress != nil {
				progress(n)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			out.Close()
			os.Remove(tmp)
			return rerr
		}
	}
	out.Close()
	got := hex.EncodeToString(h.Sum(nil))
	if (sum != "" && got != sum) || (size > 0 && n != size) {
		os.Remove(tmp)
		return errors.New("the file is damaged (SHA-256 mismatch)")
	}
	return os.Rename(tmp, dst)
}
