//go:build updateserver

package main

// The admin web page: one account ("admin"), a one-time password after a
// new install or a reset that must be changed before anything else,
// sign-out after 30 minutes without activity, and a lock after 5 wrong
// passwords. The front end (web/) is plain HTML + JS calling /api/.

import (
	"embed"
	"encoding/base64"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"rsc.io/qr"
)

//go:embed web
var embeddedWeb embed.FS

const maxUpload = 400 << 20

// webServer: the shared sign-in portal (webadmin.go) plus the server's API.
type webServer struct {
	*portal
	cfg *serverConfig
	st  *store
	srv *updateServer
	log *logRing
	job importJob
}

func newWebServer(cfg *serverConfig, st *store, srv *updateServer, lr *logRing) *webServer {
	return &webServer{portal: newPortal(st, cfg.ScryptN, "gundil_server_session"), cfg: cfg, st: st, srv: srv, log: lr}
}

// ---------------------------------------------------------------- routes

func (w *webServer) handler() http.Handler {
	m := http.NewServeMux()
	w.routes(m)
	m.HandleFunc("GET /api/status", w.auth(false, w.apiStatus))
	m.HandleFunc("GET /api/qr.svg", w.auth(false, w.apiQR))
	m.HandleFunc("POST /api/check", w.auth(false, w.apiCheck))
	m.HandleFunc("GET /api/devices", w.auth(false, w.apiDevices))
	m.HandleFunc("POST /api/devices/{id}", w.auth(false, w.apiDeviceSet))
	m.HandleFunc("DELETE /api/devices/{id}", w.auth(false, w.apiDeviceDelete))
	m.HandleFunc("GET /api/policy", w.auth(false, w.apiPolicy))
	m.HandleFunc("POST /api/policy", w.auth(false, w.apiPolicySet))
	m.HandleFunc("GET /api/versions", w.auth(false, w.apiVersions))
	m.HandleFunc("GET /api/github", w.auth(false, w.apiGithub))
	m.HandleFunc("POST /api/versions/import", w.auth(false, w.apiImport))
	m.HandleFunc("POST /api/versions/upload", w.auth(false, w.apiUpload))
	m.HandleFunc("DELETE /api/versions/{version}", w.auth(false, w.apiVersionDelete))
	m.HandleFunc("GET /api/log", w.auth(false, w.apiLog))
	m.Handle("/", w.static())
	return securityHeaders(m)
}

func (w *webServer) static() http.Handler {
	var root fs.FS
	if w.cfg.WebDir != "" && fileExists(filepath.Join(w.cfg.WebDir, "index.html")) {
		root = os.DirFS(w.cfg.WebDir)
	} else {
		root, _ = fs.Sub(embeddedWeb, "web")
	}
	return http.FileServer(http.FS(root))
}

func (w *webServer) apiStatus(rw http.ResponseWriter, r *http.Request) {
	pub, nat := w.srv.stun(false)
	devs := w.st.deviceList()
	recent := 0
	for _, d := range devs {
		if time.Since(d.LastSeen) < 24*time.Hour {
			recent++
		}
	}
	pubText := ""
	if pub != nil {
		pubText = pub.String()
	}
	writeJSONResp(rw, 200, map[string]any{
		"version": version, "code": w.srv.code(), "relays": w.srv.nostr.connected(),
		"relaysTotal": len(w.cfg.Relays), "nat": nat, "public": pubText, "devices": len(devs),
		"recent": recent, "links": w.srv.links.Load(), "dataDir": w.cfg.DataDir,
		"repo": w.cfg.Repo, "job": w.job.snapshot(),
	})
}

func (w *webServer) apiQR(rw http.ResponseWriter, r *http.Request) {
	c, err := qr.Encode(w.srv.code(), qr.M)
	if err != nil {
		fail(rw, 500, err.Error())
		return
	}
	var b strings.Builder
	n := c.Size + 8
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges"><rect width="%d" height="%d" fill="#fff"/><path fill="#000" d="`, n, n, n, n)
	for y := 0; y < c.Size; y++ {
		for x := 0; x < c.Size; x++ {
			if c.Black(x, y) {
				fmt.Fprintf(&b, "M%d %dh1v1h-1z", x+4, y+4)
			}
		}
	}
	b.WriteString(`"/></svg>`)
	rw.Header().Set("Content-Type", "image/svg+xml")
	rw.Write([]byte(b.String()))
}

func (w *webServer) apiCheck(rw http.ResponseWriter, r *http.Request) {
	pub, nat := w.srv.stun(true)
	pubText := ""
	if pub != nil {
		pubText = pub.String()
	}
	writeJSONResp(rw, 200, map[string]any{"relays": w.srv.nostr.connected(),
		"relaysTotal": len(w.cfg.Relays), "nat": nat, "public": pubText})
}

func (w *webServer) apiDevices(rw http.ResponseWriter, r *http.Request) {
	devs := w.st.deviceList()
	out := make([]map[string]any, 0, len(devs))
	for _, d := range devs {
		out = append(out, map[string]any{"id": d.ID, "name": d.Name, "package": d.Package,
			"family": familyOf(d.Package), "version": d.Version, "os": d.OS, "address": d.Address,
			"firstSeen": d.FirstSeen, "lastSeen": d.LastSeen, "pin": d.Pin, "offered": d.Offered,
			"fetched": d.Fetched})
	}
	writeJSONResp(rw, 200, out)
}

func (w *webServer) apiDeviceSet(rw http.ResponseWriter, r *http.Request) {
	var m struct{ Pin string }
	if readBody(r, &m) != nil || (m.Pin != "" && !validVersion(m.Pin)) {
		fail(rw, 400, "bad version")
		return
	}
	if !w.st.updateDevice(r.PathValue("id"), func(d *device) { d.Pin = strings.TrimPrefix(m.Pin, "v") }) {
		fail(rw, 404, "no such device")
		return
	}
	w.st.flushDevices()
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiDeviceDelete(rw http.ResponseWriter, r *http.Request) {
	w.st.deleteDevice(r.PathValue("id"))
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiPolicy(rw http.ResponseWriter, r *http.Request) {
	writeJSONResp(rw, 200, map[string]any{"families": families, "policy": w.st.allPolicy()})
}

func (w *webServer) apiPolicySet(rw http.ResponseWriter, r *http.Request) {
	var m map[string]familyPolicy
	if readBody(r, &m) != nil {
		fail(rw, 400, "bad request")
		return
	}
	for k, p := range m {
		known := false
		for _, f := range families {
			known = known || f.ID == k
		}
		if !known || (p.Mode != "off" && p.Mode != "ask" && p.Mode != "auto") ||
			(p.Target != "" && p.Target != "latest" && !validVersion(p.Target)) {
			fail(rw, 400, "bad policy for "+k)
			return
		}
		p.Target = strings.TrimPrefix(p.Target, "v")
		m[k] = p
	}
	if err := w.st.setPolicy(m); err != nil {
		fail(rw, 500, err.Error())
		return
	}
	log.Printf("web: policy changed")
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiVersions(rw http.ResponseWriter, r *http.Request) {
	writeJSONResp(rw, 200, map[string]any{"versions": w.st.versionList(), "job": w.job.snapshot()})
}

func (w *webServer) apiGithub(rw http.ResponseWriter, r *http.Request) {
	rels, err := githubReleases(w.cfg.Repo)
	if err != nil {
		fail(rw, 502, "Could not read the releases from GitHub: "+err.Error())
		return
	}
	out := []map[string]any{}
	for _, rel := range rels {
		n := 0
		for _, a := range rel.Assets {
			if p, _ := packageOf(a.Name); p != "" {
				n++
			}
		}
		out = append(out, map[string]any{"tag": rel.Tag, "name": rel.Name, "published": rel.Published,
			"prerelease": rel.Prerelease, "files": n})
	}
	writeJSONResp(rw, 200, out)
}

func (w *webServer) apiImport(rw http.ResponseWriter, r *http.Request) {
	var m struct {
		Tag  string
		Keep []string
	}
	if readBody(r, &m) != nil || !validVersion(m.Tag) {
		fail(rw, 400, "bad request")
		return
	}
	if w.job.snapshot()["running"] == true {
		fail(rw, 409, "Copies of another version are still downloading.")
		return
	}
	keep := map[string]bool{}
	for _, k := range m.Keep {
		keep[k] = true
	}
	if err := importRelease(w.st, w.cfg.Repo, m.Tag, keep, &w.job); err != nil {
		fail(rw, 502, err.Error())
		return
	}
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

// apiUpload: a release file from the admin's computer, kept on this server.
func (w *webServer) apiUpload(rw http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(rw, r.Body, maxUpload)
	mr, err := r.MultipartReader()
	if err != nil {
		fail(rw, 400, "bad upload")
		return
	}
	var added []string
	var sums, sig string // A release's SHA256SUMS.txt and .sig, uploaded with its files.
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			fail(rw, 400, "upload interrupted: "+err.Error())
			return
		}
		name := filepath.Base(part.FileName())
		if name == "" || name == "." {
			continue
		}
		switch name {
		case "SHA256SUMS.txt", "app-SHA256SUMS.txt":
			b, _ := io.ReadAll(io.LimitReader(part, 1<<20))
			sums = string(b)
			continue
		case "SHA256SUMS.txt.sig":
			b, _ := io.ReadAll(io.LimitReader(part, 4096))
			sig = base64.StdEncoding.EncodeToString(b)
			continue
		}
		pkg, v := packageOf(name)
		if pkg == "" {
			fail(rw, 400, name+" is not a Gundil Intercom release file (keep its original name).")
			return
		}
		f := versionFile{Name: stripPrefix(name), Asset: name, Package: pkg, Local: true}
		dst := w.st.filePath(v, f.Name)
		os.MkdirAll(filepath.Dir(dst), 0o700)
		h := &hashCounter{}
		if err := saveChecked(dst, io.TeeReader(part, h), "", 0, nil); err != nil {
			fail(rw, 500, err.Error())
			return
		}
		f.Size, f.SHA256 = h.n, h.sum()
		// Keep the GitHub link when the same file is there already.
		if old := w.st.fileFor(v, pkg); old != nil && old.SHA256 == f.SHA256 {
			f.URL = old.URL
		}
		if err := w.st.addFiles(v, "upload", "", []versionFile{f}); err != nil {
			fail(rw, 500, err.Error())
			return
		}
		added = append(added, name)
		log.Printf("web: uploaded %s (%d KB)", name, f.Size/1024)
	}
	out := map[string]any{"ok": true, "files": added}
	switch {
	case sums != "" && sig != "":
		// The versions the list names (and that are here).
		var signed []string
		seen := map[string]bool{}
		for _, line := range strings.Split(sums, "\n") {
			f := strings.Fields(line)
			if len(f) != 2 {
				continue
			}
			if _, v := packageOf(strings.TrimPrefix(f[1], "*")); v != "" && !seen[v] {
				seen[v] = true
				if w.st.setSignature(v, sums, sig) == nil {
					signed = append(signed, v)
					log.Printf("web: signature uploaded for %s: %s", v, signatureNote(sums, sig))
				}
			}
		}
		out["signed"] = signed
	case sums != "" || sig != "":
		out["warning"] = "Upload SHA256SUMS.txt and SHA256SUMS.txt.sig together."
	case len(added) > 0 && releaseKey != "":
		out["warning"] = "Devices only install signed releases: also upload the release's SHA256SUMS.txt and SHA256SUMS.txt.sig."
	}
	writeJSONResp(rw, 200, out)
}

func (w *webServer) apiVersionDelete(rw http.ResponseWriter, r *http.Request) {
	if err := w.st.deleteVersion(r.PathValue("version")); err != nil {
		fail(rw, 404, err.Error())
		return
	}
	log.Printf("web: version %s removed", r.PathValue("version"))
	writeJSONResp(rw, 200, map[string]any{"ok": true})
}

func (w *webServer) apiLog(rw http.ResponseWriter, r *http.Request) {
	writeJSONResp(rw, 200, map[string]any{"lines": w.log.lines()})
}
