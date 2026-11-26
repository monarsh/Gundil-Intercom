//go:build !updateserver

// gundil-gateway: lets the Gundil Intercom apps reach the cameras on a home
// LAN from anywhere, through public Nostr relays and UDP hole punching. It
// runs on an OpenWrt router, a Raspberry Pi / Orange Pi, a Linux server or
// a Windows PC.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

var version = "dev"

var svcSpec = serviceSpec{
	name:        "GundilGateway",
	display:     "Gundil Intercom gateway",
	description: "Lets the Gundil Intercom apps reach the cameras on this LAN over the internet.",
	firewall:    "Gundil gateway",
	template:    configTemplate,
	// With the web page the settings can be made there, after installing.
	needsConfig: false,
	check: func(p string) error {
		c, err := parseConfig(p)
		if err == nil && !c.Web {
			err = c.authProblem()
		}
		return err
	},
	installed: func(cfgPath string) { // Windows: where the web page is.
		c, err := parseConfig(cfgPath)
		if err != nil || !c.Web {
			return
		}
		_, port, _ := net.SplitHostPort(c.WebListen)
		fmt.Printf("Web page: http://localhost:%s (or this PC's address, from the local network).\n", port)
		pwFile := filepath.Join(webDataDir(c), "web-initial-password.txt")
		for i := 0; i < 20 && !fileExists(pwFile); i++ {
			time.Sleep(250 * time.Millisecond)
		}
		if b, err := os.ReadFile(pwFile); err == nil {
			fmt.Printf("Sign in as \"admin\" with the one-time password %s (you'll choose your own first).\n", strings.TrimSpace(string(b)))
		}
		if c.authProblem() != nil {
			fmt.Println("Then set the intercom password or the home key there.")
		}
	},
}

func main() {
	cfgPath := flag.String("config", defaultConfigPath(), "configuration file")
	check := flag.Bool("check", false, "check the network (relays, NAT, cameras) and exit")
	showVersion := flag.Bool("version", false, "print the version and exit")
	install := flag.Bool("install", false, "update: also install what the update server offers")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: gundil-gateway [--config=FILE] [--check] [command]

Commands:
  run            run the gateway (the default)
  reset-admin    start the web page's admin account afresh: a new one-time
                 password (in the log), which must be changed at the first
                 sign-in. Restarts the gateway service.
  update         ask the update server now; with --install also install what
                 it offers (checked against the release signature) and
                 restart the gateway service. As root / Administrator.
  install        Windows: install and start the service (as Administrator)
  uninstall      Windows: remove the service

`)
		flag.PrintDefaults()
	}
	flag.Parse()
	if *showVersion {
		fmt.Println("gundil-gateway", version)
		return
	}
	switch flag.Arg(0) {
	case "install":
		exitOn(installService(*cfgPath))
		return
	case "uninstall":
		exitOn(uninstallService())
		return
	case "update":
		// "update --install": flags after the command too.
		for _, a := range flag.Args()[1:] {
			switch a {
			case "--install", "-install":
				*install = true
			default:
				flag.Usage()
				os.Exit(2)
			}
		}
		exitOn(updateCommand(*cfgPath, *install))
		return
	case "reset-admin":
		cfg, err := parseConfig(*cfgPath)
		exitOn(err)
		exitOn(resetWebAdmin(cfg))
		restartService()
		return
	case "", "run":
	default:
		flag.Usage()
		os.Exit(2)
	}
	if runAsService(func() { serve(*cfgPath, false) }) {
		return
	}
	serve(*cfgPath, *check)
}

func serve(cfgPath string, check bool) {
	log.SetFlags(log.Ldate | log.Ltime)
	if exe, err := os.Executable(); err == nil {
		os.Remove(exe + ".old") // Left by a self-update on Windows.
	}
	if check {
		cfg, err := loadConfig(cfgPath)
		exitOn(err)
		st, err := loadState(cfg.StatePath)
		exitOn(err)
		g, err := newGateway(cfg, st, cfg.ScryptN)
		exitOn(err)
		g.nostr.start()
		g.check()
		return
	}
	ring := &logRing{}
	log.SetOutput(io.MultiWriter(log.Writer(), ring))
	cfg, err := parseConfig(cfgPath)
	exitOn(err)
	var web *gatewayWeb
	if cfg.Web {
		web, err = newGatewayWeb(cfg, ring)
		if err == nil {
			err = web.serveWeb(cfg.WebListen)
		}
		if err != nil {
			log.Printf("%v (the gateway runs without its web page)", err)
			web = nil
		}
	}
	if web == nil {
		cfg, err = loadConfig(cfgPath)
		exitOn(err)
		g, err := startGateway(cfg)
		exitOn(err)
		g.run()
		return
	}
	web.runGateways(cfgPath)
}

// startGateway: the gateway for [cfg] (not yet running).
func startGateway(cfg *config) (*gateway, error) {
	st, err := loadState(cfg.StatePath)
	if err != nil {
		return nil, err
	}
	g, err := newGateway(cfg, st, cfg.ScryptN)
	if err != nil {
		return nil, err
	}
	auth := "the intercom password"
	if cfg.Password == "" {
		auth = "home key " + homeFingerprint(cfg.HomeKey)
	}
	log.Printf("gundil-gateway %s \"%s\" (UDP port %d, %d relays, sharing cameras: %v, using %s)",
		version, cfg.Name, g.mux.port(), len(cfg.Relays), cfg.ShareCameras, auth)
	return g, nil
}

// updateCommand: "gundil-gateway update [--install]".
func updateCommand(cfgPath string, install bool) error {
	cfg, err := loadConfig(cfgPath)
	if err != nil {
		return err
	}
	st, err := loadState(cfg.StatePath)
	if err != nil {
		return err
	}
	g, err := newGateway(cfg, st, cfg.ScryptN)
	if err != nil {
		return err
	}
	defer g.stop()
	log.SetOutput(io.Discard) // Just the answer below.
	fmt.Printf("gundil-gateway %s: asking the update server…\n", version)
	installed, err := g.updateNow(install)
	if err != nil {
		return err
	}
	u := g.updateState()
	fmt.Println(u.Result)
	switch {
	case installed:
		if err := restartGatewayService(); err != nil {
			fmt.Printf("Installed; now restart the gateway (%v).\n", err)
		} else {
			fmt.Println("Restarted the gateway with the new version.")
		}
	case u.Offer != "" && !install:
		fmt.Printf("Install it with: gundil-gateway update --install\n")
	}
	return nil
}

// restartGatewayService restarts the installed gateway service.
func restartGatewayService() error {
	var cmd *exec.Cmd
	switch {
	case runtime.GOOS == "windows":
		cmd = exec.Command("powershell", "-NoProfile", "-Command", "Restart-Service "+svcSpec.name)
	case isOpenWrt():
		cmd = exec.Command("/etc/init.d/gundil-gateway", "restart")
	default:
		cmd = exec.Command("systemctl", "restart", "gundil-gateway")
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%v %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// restartService restarts the installed gateway service (after
// reset-admin), so it makes the new account; or says how.
func restartService() {
	if isOpenWrt() {
		fmt.Println("On OpenWrt the gateway is set up in LuCI (Services > Gundil gateway); it has no web page of its own.")
		return
	}
	if err := restartGatewayService(); err != nil {
		fmt.Println("Now restart the gateway (sudo systemctl restart gundil-gateway, or Restart-Service GundilGateway on Windows); its log shows the new one-time password.")
		return
	}
	fmt.Println("Restarted the gateway. Its log shows the new one-time password, e.g.:")
	if runtime.GOOS == "windows" {
		fmt.Println("  Get-EventLog Application -Source GundilGateway -Newest 20")
	} else {
		fmt.Println("  sudo journalctl -u gundil-gateway -n 20 | grep '\\*\\*\\*'")
	}
}

func exitOn(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "gundil-gateway:", err)
		os.Exit(1)
	}
}
