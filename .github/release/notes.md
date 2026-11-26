Two-way (full-duplex) LAN intercom for **Android, iPhone, Windows, Mac, Linux, Raspberry Pi and Orange Pi PC**.
Pick an intercom, press **Connect**, and both sides talk and listen at the same time until one hangs up.
During a call, Android, Windows and Linux can turn on their camera for video. IP cameras (TP-Link Tapo and other RTSP cameras) can be watched live.
Intercoms find each other automatically on the same Wi-Fi/LAN. No server, no account. Optionally, your own update server keeps every intercom on the version you choose.

## Which file do I need?

| Device | File |
|---|---|
| **Windows 10/11** | `app-Gundil_Intercom-VERSION-windows-x64-setup.exe` (installer). Portable alternative: `…-windows-x64-portable.zip` |
| **Android** phone/tablet | `app-Gundil_Intercom-VERSION-android-arm64-v8a.apk` (most phones). If unsure: `…-android-universal.apk` |
| **iPhone / iPad** (iOS 15+) | `app-Gundil_Intercom-VERSION-ios-unsigned.ipa`, installed with AltStore or Sideloadly (see below) |
| **Mac** (macOS 12+, Apple silicon or Intel) | `app-Gundil_Intercom-VERSION-macos.zip` |
| **Linux PC** (x86_64) | `app-gundil-intercom-VERSION-x86_64.AppImage` (`chmod +x` it and run). Or `…-linux-x64.tar.gz` |
| **Raspberry Pi 4/5** with desktop, 64-bit OS | `app-gundil-intercom-VERSION-aarch64.AppImage`. Or `…-linux-arm64.tar.gz` |
| **Orange Pi PC**, Raspberry Pi with 32-bit OS, no screen | `app-gundil-intercom-node-VERSION-linux-arm.tar.gz` (headless node, see below) |
| Raspberry Pi / Orange Pi with 64-bit OS, no screen | `app-gundil-intercom-node-VERSION-linux-arm64.tar.gz` |

**Camera gateway** (`gundil-gateway`: reach the cameras at home from outside, see below):

| Device at home | File |
|---|---|
| **OpenWrt router**, ARM 64-bit (Filogic, Rockchip, IPQ807x…) | `app-gundil-gateway-VERSION-openwrt-aarch64.ipk` |
| OpenWrt router, ARM 32-bit / MIPS (MT7621) / MIPS (ath79) / x86 | `…-openwrt-arm.ipk` / `…-openwrt-mipsel.ipk` / `…-openwrt-mips.ipk` / `…-openwrt-x86_64.ipk` |
| OpenWrt web page (LuCI: **Services → Gundil gateway**), any router, together with one of the above | `app-gundil-gateway-VERSION-openwrt-luci.ipk` |
| **OpenWrt 25 and newer** (uses `apk`, not `opkg`): the same, as `.apk` | `app-gundil-gateway-VERSION-openwrt25-aarch64.apk` (or `…-arm`, `…-mipsel`, `…-mips`, `…-x86_64`) + `…-openwrt25-luci.apk` |
| Raspberry Pi 3/4/5 or Orange Pi, 64-bit OS | `app-gundil-gateway-VERSION-linux-arm64.tar.gz` |
| Orange Pi PC (H3), Pi with 32-bit OS / Pi Zero | `…-linux-armv7.tar.gz` / `…-linux-armv6.tar.gz` |
| Linux PC or server | `app-gundil-gateway-VERSION-linux-x86_64.tar.gz` |
| Windows PC | `app-gundil-gateway-VERSION-windows-x86_64.zip` (or `…-arm64.zip`) |
| Any of these, installed from your computer over SSH | `app-gundil-gateway-deploy.sh` (`./app-gundil-gateway-deploy.sh root@192.168.1.1` installs the newest release; `--version X.Y.Z` another one; `--home-key` sets the home key) |

**Update server** (`gundil-update-server`: tells every Gundil Intercom which version to install and hands out the files, without a public IP; admin web page; see below). Its files start with `server-`:

| Server | File |
|---|---|
| Linux PC or server (x86_64), any distribution with systemd | `server-gundil-update-server-VERSION-linux-x86_64.tar.gz` |
| Raspberry Pi 3/4/5, Orange Pi (64-bit OS) | `…-linux-arm64.tar.gz` |
| Orange Pi PC (H3), Pi with 32-bit OS / Pi Zero | `…-linux-armv7.tar.gz` / `…-linux-armv6.tar.gz` |
| OpenWrt router (OpenWrt 25+, `apk`) | `server-gundil-update-server-VERSION-openwrt25-aarch64.apk` (or `…-arm`, `…-mipsel`, `…-mips`, `…-x86_64`) |
| OpenWrt router (older, `opkg`) | `…-openwrt-aarch64.ipk` (or `…-arm`, `…-mipsel`, `…-mips`, `…-x86_64`) |
| OpenWrt web page (LuCI: **Services → Gundil update server**), together with one of the above | `server-gundil-update-server-VERSION-openwrt25-luci.apk` / `…-openwrt-luci.ipk` |
| Windows PC (a service) | `server-gundil-update-server-VERSION-windows-x86_64.zip` (or `…-arm64.zip`) |
| Any desktop Linux, one file | `server-gundil-update-server-VERSION-x86_64.AppImage` (or `…-aarch64.AppImage`) |
| Your computer: deploy over SSH, reset the portal | `server-gundil-update-server-VERSION-tools.zip` (`deploy.sh`, `reset-portal.sh`, `reset-portal.ps1`, the web page) |

The app's files start with `app-`. `SHA256SUMS.txt` lists checksums for every file.

## Install notes

- **Windows:** SmartScreen may warn about an unknown publisher (the installer isn't code-signed). Choose *More info → Run anyway*. The installer adds the firewall rule, a Start-menu entry and optional autostart. The app keeps running in the system tray. Later versions install themselves from your update server (*⋮ More → Updates*).
- **Android:** allow *Install unknown apps*. The APKs are signed with a development key, which is fine for installing yourself, not for the Play Store. For always-on use, turn on *Settings → Run in background*.
- **iPhone / iPad:** Apple only allows signed apps, and this one isn't signed by a paid Apple Developer account. Install the `.ipa` with [AltStore](https://altstore.io) or [Sideloadly](https://sideloadly.io) using your own (free) Apple ID; with a free Apple ID the app must be refreshed every 7 days (AltStore does this by itself). Allow *Local Network* and *Microphone* when asked. iPhones can't find intercoms automatically (iOS blocks the LAN broadcast without a special Apple permission): add them with **Add peer by IP**. To keep the iPhone answering with the screen locked, turn on *Settings → Run in background* (it plays silence in the background, which uses some battery).
- **Mac:** unzip and move *Gundil Intercom* to Applications. The app isn't notarized by Apple, so the first time right-click it → *Open* → *Open* (or *System Settings → Privacy & Security → Open Anyway*). Allow *Microphone* and *Local Network* when asked.
- **Linux AppImage:** the first time it starts, it adds itself to your app menu with its icon (`~/.local/share/applications` and `~/.local/share/icons`), so the dock or taskbar shows the Gundil icon and you can pin it (not when AppImageLauncher or a similar tool already added it); delete those two `gundil-intercom`/`com.p2pintercom.p2p_intercom` files to undo, or start it with `GUNDIL_NO_DESKTOP_ENTRY=1` to skip this. On Ubuntu 22.04+ you may need `sudo apt install libfuse2` (`libfuse2t64` on 24.04), or run it with `--appimage-extract-and-run`. For the tray icon, the desktop needs a tray and `libayatana-appindicator3-1` (preinstalled on Ubuntu and Linux Mint).
- **Orange Pi PC / Raspberry Pi node:** `tar xzf *gundil-intercom-node-*.tar.gz`, `cd` into the folder, then `sudo ./install.sh`. It answers incoming connections automatically and connects with a GPIO button. Wiring and audio setup are in [node/README.md](https://github.com/monarsh/p2p-intercom/blob/vVERSION/node/README.md).
- **Camera gateway on OpenWrt:** copy the `.ipk` to the router (`scp`), then `opkg install /tmp/*gundil-gateway-*.ipk`, `uci set gundil.main.password='your intercom password'` (or, if your apps use no password, `uci set gundil.main.home_key='GUNDIL-PAIR-…'` with the pairing code from a paired app), `uci set gundil.main.share_cameras=1`, `uci commit gundil`, `/etc/init.d/gundil-gateway start`. Check it with `gundil-gateway --check --config=/var/etc/gundil-gateway.conf` and `logread -e gundil`. About 7 MB installed. **With LuCI:** install `…-openwrt-luci.ipk` too (`opkg install /tmp/*gundil-gateway-*.ipk` installs both), then set everything in the router's web page under **Services → Gundil gateway**: password or home key, Share home cameras, Save & Apply; the page also has Check network, Show log and Restart. **OpenWrt 25+** (no `opkg`, `apk` instead): copy the two `…-openwrt25-….apk` files and run `apk add --allow-untrusted /tmp/*gundil-gateway-*.apk` (the packages aren't signed with OpenWrt's key, hence `--allow-untrusted`).
- **Camera gateway on Linux (Pi, Orange Pi, PC):** `tar xzf *gundil-gateway-*.tar.gz`, `cd` into the folder, `sudo ./install.sh`. **On Windows:** unzip, then in an Administrator prompt `gundil-gateway.exe install` (it runs as a Windows service). Both print the address of the gateway's **web page**, `http://<device>:8781` (local network only), and a one-time password: sign in as `admin`, choose your own password, then set the intercom password or home key, Share home cameras and Save and restart. Or set `password` / `home_key` in `/etc/gundil-gateway.conf` (Windows: `C:\ProgramData\Gundil\gateway.conf`) and restart the gateway.
- **Update server:** from your computer, `./deploy.sh root@192.168.1.1` (in the tools zip) installs it on a Linux box, OpenWrt router or Windows PC over SSH. Or by hand: Linux `sudo ./install.sh` in the unpacked folder; OpenWrt `apk add --allow-untrusted /tmp/*gundil-update-server-*.apk` (with the `…-luci.apk` too: **Services → Gundil update server** in the router's web page shows the status and server code, opens the admin page, changes the settings and resets the portal); Windows `gundil-update-server.exe install` as Administrator; AppImage: just run it. Then open `http://<server>:8780`, sign in as `admin` with the one-time password from its log, and choose a new password. Copy the **server code** (Server tab) into the repository variable `GUNDIL_UPDATE_SERVER` so the next builds have it, or paste it in each app under **⋮ More → Updates**. `gundil-reset-portal` starts the portal afresh.
- **All devices need 1.2.0 or newer** (encrypted calls). Older versions show as *Needs update* and can't connect, so update every intercom, including the Orange Pi / Raspberry Pi nodes.

## Network

Same LAN/Wi-Fi, or anywhere with *Internet calls* on (STUN + UDP hole punching through public Nostr relays; no VPN, no server of your own). Allow **TCP 47801** (audio and video) and **UDP 47800** (discovery). Audio (uncompressed 16 kHz mono) and video (JPEG pictures) are end-to-end encrypted. Set the same *intercom password* on every device so unknown devices can't connect.
