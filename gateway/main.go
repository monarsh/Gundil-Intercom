// gundil-gateway: lets the Gundil Intercom apps reach the cameras on a home
// LAN from anywhere, through public Nostr relays and UDP hole punching. It
// runs on an OpenWrt router, a Raspberry Pi / Orange Pi, a Linux server or
// a Windows PC.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
)

var version = "dev"

func main() {
	cfgPath := flag.String("config", defaultConfigPath(), "configuration file")
	check := flag.Bool("check", false, "check the network (relays, NAT, cameras) and exit")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: gundil-gateway [--config=FILE] [--check] [install|uninstall]\n\n")
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
	cfg, err := loadConfig(cfgPath)
	exitOn(err)
	st, err := loadState(cfg.StatePath)
	exitOn(err)
	g, err := newGateway(cfg, st, cfg.ScryptN)
	exitOn(err)
	if check {
		g.nostr.start()
		g.check()
		return
	}
	log.Printf("gundil-gateway %s \"%s\" (UDP port %d, %d relays, sharing cameras: %v)",
		version, cfg.Name, g.mux.port(), len(cfg.Relays), cfg.ShareCameras)
	g.run()
}

func exitOn(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "gundil-gateway:", err)
		os.Exit(1)
	}
}
