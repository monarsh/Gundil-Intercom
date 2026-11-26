//go:build updateserver

// gundil-update-server: tells every Gundil Intercom worldwide which version
// to install (upgrade or downgrade), and hands out the files. It needs no
// public IP: devices reach it through public Nostr relays, STUN and UDP hole
// punching. An admin web page manages the versions and devices.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"hash"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var version = "dev"

var svcSpec = serviceSpec{
	name:        "GundilUpdateServer",
	display:     "Gundil Intercom update server",
	description: "Tells the Gundil Intercom apps which version to install, and hands out the files.",
	firewall:    "Gundil update server",
	template:    serverConfigTemplate,
	check:       func(p string) error { _, err := loadServerConfig(p); return err },
}

func main() {
	cfgPath := flag.String("config", defaultServerConfigPath(), "configuration file (optional)")
	showVersion := flag.Bool("version", false, "print the version and exit")
	all := flag.Bool("all", false, "reset-admin: also forget the devices, the policy and the versions")
	newKey := flag.Bool("new-key", false, "reset-admin: also make a new server key (every installed app loses the server)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: gundil-update-server [--config=FILE] [command]

Commands:
  run            run the server (the default)
  code           print the server code (built into the apps)
  export-key     print the server key (secret), to move the server to
                 another machine with the same server code
  import-key KEY use that server key here (KEY, or "-" to read it from
                 stdin); stop the server first, start it afterwards
  reset-admin    start the admin account afresh: a new one-time password,
                 which must be changed at the first sign-in. With --all also
                 forget devices, policy and versions; --new-key also makes a
                 new server key. Stop the server first.
  install        Windows: install and start the service (as Administrator)
  uninstall      Windows: remove the service

`)
		flag.PrintDefaults()
	}
	flag.Parse()
	if *showVersion {
		fmt.Println("gundil-update-server", version)
		return
	}
	switch flag.Arg(0) {
	case "install":
		exitOn(installService(*cfgPath))
		return
	case "uninstall":
		exitOn(uninstallService())
		return
	case "code":
		cfg, err := loadServerConfig(*cfgPath)
		exitOn(err)
		st, err := openStore(cfg.DataDir)
		exitOn(err)
		fmt.Println(updateCodeText(st.serverKey().pub))
		return
	case "export-key":
		cfg, err := loadServerConfig(*cfgPath)
		exitOn(err)
		exitOn(exportKeyCommand(cfg.DataDir))
		return
	case "import-key":
		cfg, err := loadServerConfig(*cfgPath)
		exitOn(err)
		exitOn(importKeyCommand(cfg.DataDir, flag.Arg(1)))
		return
	case "reset-admin":
		cfg, err := loadServerConfig(*cfgPath)
		exitOn(err)
		exitOn(resetAdmin(cfg.DataDir, *all, *newKey))
		return
	case "", "run":
	default:
		flag.Usage()
		os.Exit(2)
	}
	if runAsService(func() { serve(*cfgPath) }) {
		return
	}
	serve(*cfgPath)
}

func resetAdmin(dir string, all, newKey bool) error {
	if !fileExists(dir) {
		return fmt.Errorf("no data in %s", dir)
	}
	rm := func(name string) {
		if err := os.RemoveAll(filepath.Join(dir, name)); err == nil {
			fmt.Println("removed", filepath.Join(dir, name))
		}
	}
	rm("admin.json")
	rm("initial-password.txt")
	if all {
		rm("devices.json")
		rm("policy.json")
		rm("versions.json")
		rm("files")
	}
	if newKey {
		rm("keys.json")
		fmt.Println("A new server key is made at the next start: put the new server code into the apps.")
	}
	fmt.Println("Done. Start the server: it shows a new one-time password for the admin account.")
	return nil
}

func serve(cfgPath string) {
	ring := &logRing{}
	log.SetOutput(io.MultiWriter(os.Stderr, ring))
	log.SetFlags(log.Ldate | log.Ltime)
	cfg, err := loadServerConfig(cfgPath)
	exitOn(err)
	st, err := openStore(cfg.DataDir)
	exitOn(err)
	pw, err := ensureAdmin(st, cfg.ScryptN)
	exitOn(err)
	srv, err := newUpdateServer(cfg, st)
	exitOn(err)
	web := newWebServer(cfg, st, srv, ring)
	ln, err := net.Listen("tcp", cfg.Listen)
	exitOn(err)
	log.Printf("gundil-update-server %s: web page on %s, UDP port %d, %d relays, data in %s",
		version, pageURLs(ln.Addr()), srv.mux.port(), len(cfg.Relays), cfg.DataDir)
	log.Printf("server code (built into the apps): %s", srv.code())
	if pw != "" {
		// Not into the web log: only the console / system log.
		fmt.Fprintf(os.Stderr, "\n*** New admin account. Sign in at %s as \"admin\" with the one-time password:\n***     %s\n*** (also in %s). You must change it at the first sign-in.\n\n",
			pageURLs(ln.Addr()), pw, st.path("initial-password.txt"))
	} else if a := st.adminAccount(); a != nil && a.MustChange {
		fmt.Fprintf(os.Stderr, "The one-time admin password is in %s until it's changed.\n", st.path("initial-password.txt"))
	}
	if !cfg.TestNoNet {
		go srv.run()
		go backfillSignatures(st, cfg.Repo)
		go web.self.runChecks()
	}
	hs := &http.Server{Handler: web.handler(), ReadHeaderTimeout: 10 * time.Second}
	exitOn(hs.Serve(ln))
}

// pageURLs: how to open the web page, e.g. http://192.168.1.1:8780.
func pageURLs(a net.Addr) string {
	host, port, _ := net.SplitHostPort(a.String())
	if host != "0.0.0.0" && host != "::" && host != "" {
		return "http://" + net.JoinHostPort(host, port)
	}
	var urls []string
	for _, ip := range ownIPv4() {
		urls = append(urls, "http://"+net.JoinHostPort(ip, port))
	}
	if len(urls) == 0 {
		return "http://localhost:" + port
	}
	return strings.Join(urls, " or ")
}

func exitOn(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "gundil-update-server:", err)
		os.Exit(1)
	}
}

// hashCounter: SHA-256 and size of what passes through.
type hashCounter struct {
	h hash.Hash
	n int64
}

func (c *hashCounter) Write(p []byte) (int, error) {
	if c.h == nil {
		c.h = sha256.New()
	}
	c.h.Write(p)
	c.n += int64(len(p))
	return len(p), nil
}

func (c *hashCounter) sum() string {
	if c.h == nil {
		c.h = sha256.New()
	}
	return hex.EncodeToString(c.h.Sum(nil))
}
