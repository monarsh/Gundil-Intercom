Gundil Intercom update server
=============================

Tells every Gundil Intercom (Android, Windows, Mac, Linux, iPhone, the
headless node and gundil-gateway) which version to install, upgrade or
downgrade, and hands out the files. It needs no public IP and no port
forwarding: the apps reach it through public Nostr relays, STUN and UDP
hole punching, like internet calls.

Install
-------
Linux (PC, Raspberry Pi, Orange Pi; systemd):
    tar xzf gundil-update-server-*-linux-<cpu>.tar.gz
    cd gundil-update-server-*/ && sudo ./install.sh
OpenWrt:     apk add --allow-untrusted gundil-update-server-*-openwrt25-<cpu>.apk
             (older OpenWrt: opkg install gundil-update-server-*-openwrt-<cpu>.ipk)
             LuCI page (Services > Gundil update server): add the -luci package too.
Windows:     unzip, then as Administrator:  gundil-update-server.exe install
AppImage:    chmod +x gundil-update-server-*.AppImage && ./gundil-update-server-*.AppImage
From your computer over SSH (any of the above):
             ./deploy.sh root@192.168.1.1     (the newest release;
             --version X.Y.Z for another one)
It can share a machine with gundil-gateway (e.g. the same OpenWrt router):
separate programs, settings and data; only TCP 8780 (admin page) is fixed.

First sign-in
-------------
Open http://<server address>:8780 and sign in as "admin" with the one-time
password from the server's log (also in initial-password.txt in its data
folder). You must choose a new password (10+ characters) before anything
else. There is only this one account. After 30 minutes without activity
you're signed out; 5 wrong passwords lock the sign-in for 5 minutes.

Then
----
1. Server tab: copy the server code (GUNDIL-UPDATE-...). Put it into the
   GitHub repository variable GUNDIL_UPDATE_SERVER so every build has it, or
   paste it in each app: Settings > Updates > Update server.
2. Versions tab: add releases from GitHub (optionally keep copies here).
3. Policy tab: pick the version per kind of device and Off / Ask /
   Install automatically. Devices tab: pin one device to a version.

Reset the portal
----------------
    sudo gundil-reset-portal            new admin account (one-time password)
    sudo gundil-reset-portal --all      also forget devices, policy, versions
    sudo gundil-reset-portal --all --new-key   ...and a new server key
Windows: .\reset-portal.ps1 [-All] [-NewKey] as Administrator.
A new server key cuts off every installed app until it gets the new code.

Files
-----
Data: /var/lib/gundil-update-server (Linux), /etc/gundil-update-server
(OpenWrt), %ProgramData%\Gundil\update-server (Windows),
~/.local/share/gundil-update-server (AppImage). Settings (optional):
/etc/gundil-update-server.conf, /etc/config/gundil-update (OpenWrt),
%ProgramData%\Gundil\update-server.conf (Windows).
