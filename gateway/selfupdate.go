package main

// Installing a new version of this program, shared by the gateway
// (gateway_update.go) and the update server (server_selfupdate.go):
// download, SHA-256, take the program (and the web page) out of the release
// archive, put it in place of the running one, restart.

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// restartForUpdate exits so the service manager starts the new program.
func restartForUpdate() {
	time.Sleep(500 * time.Millisecond)
	os.Exit(75) // Not 0: systemd (Restart=on-failure), procd and Windows restart it.
}

func fetchURL(url, dst string) error {
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("User-Agent", "gundil-"+filepath.Base(programName()))
	resp, err := (&http.Client{Timeout: 30 * time.Minute}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download: %s", resp.Status)
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, resp.Body)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

func programName() string {
	exe, err := os.Executable()
	if err != nil {
		return "program"
	}
	return strings.TrimSuffix(filepath.Base(exe), ".exe")
}

func fileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// installGatewayFile takes the gateway out of the release file (tar.gz or
// zip) and puts it in place of the running one.
func installGatewayFile(archive string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	return installProgram(archive, "gundil-gateway", exe)
}

// installProgram puts program [name] (".exe" added on Windows) from
// [archive] in place of [exe].
func installProgram(archive, name, exe string) error {
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	staged := exe + ".new"
	if err := extractOne(archive, name, staged); err != nil {
		os.Remove(staged)
		return err
	}
	return replaceFile(staged, exe)
}

// replaceFile moves [staged] over [exe] (a running program on Windows can
// be renamed but not overwritten).
func replaceFile(staged, exe string) error {
	os.Chmod(staged, 0o755)
	if runtime.GOOS == "windows" {
		old := exe + ".old"
		os.Remove(old)
		if err := os.Rename(exe, old); err != nil {
			os.Remove(staged)
			return err
		}
	}
	if err := os.Rename(staged, exe); err != nil {
		os.Remove(staged)
		return err
	}
	return nil
}

// canReplace: whether this process may put a new file next to [exe] (the
// service user owns the folder, and it isn't read-only).
func canReplace(exe string) error {
	p := exe + ".new"
	f, err := os.OpenFile(p, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	f.Close()
	return os.Remove(p)
}

func extractOne(archive, name, dst string) error {
	found := false
	err := walkArchive(archive, func(path string, r io.Reader) error {
		// The program at the top: "name" or "folder/name", not one deeper
		// in (e.g. under tools/).
		parts := strings.Split(strings.Trim(filepath.ToSlash(path), "/"), "/")
		if found || parts[len(parts)-1] != name || len(parts) > 2 {
			return nil
		}
		found = true
		return writeFrom(dst, r)
	})
	if err == nil && !found {
		err = errors.New("no program in the update")
	}
	return err
}

// extractDir copies the files under the folder [dir] (at any depth, e.g.
// "gundil-update-server-1.2.3-linux-arm64/web/") of [archive] into [dst].
func extractDir(archive, dir, dst string) (int, error) {
	n := 0
	err := walkArchive(archive, func(path string, r io.Reader) error {
		parts := strings.Split(filepath.ToSlash(path), "/")
		for i, p := range parts[:len(parts)-1] {
			if p != dir {
				continue
			}
			rel := parts[i+1:]
			for _, q := range rel {
				if q == ".." || q == "" {
					return nil
				}
			}
			out := filepath.Join(append([]string{dst}, rel...)...)
			if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
				return err
			}
			n++
			return writeFrom(out, r)
		}
		return nil
	})
	return n, err
}

func writeFrom(dst string, r io.Reader) error {
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, io.LimitReader(r, 100<<20))
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

// walkArchive calls [f] for every regular file in a .zip or .tar.gz.
func walkArchive(archive string, f func(path string, r io.Reader) error) error {
	if strings.HasSuffix(archive, ".zip") {
		z, err := zip.OpenReader(archive)
		if err != nil {
			return err
		}
		defer z.Close()
		for _, e := range z.File {
			if e.FileInfo().IsDir() {
				continue
			}
			r, err := e.Open()
			if err != nil {
				return err
			}
			err = f(e.Name, r)
			r.Close()
			if err != nil {
				return err
			}
		}
		return nil
	}
	fh, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer fh.Close()
	gz, err := gzip.NewReader(fh)
	if err != nil {
		return err
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if h.Typeflag == tar.TypeReg {
			if err := f(h.Name, tr); err != nil {
				return err
			}
		}
	}
}
