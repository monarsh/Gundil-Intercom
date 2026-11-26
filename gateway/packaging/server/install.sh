#!/bin/sh
# Installs gundil-update-server as a systemd service (Debian, Ubuntu,
# Raspberry Pi OS, Armbian on Orange Pi, any x86_64 or ARM Linux).
# Run from the unpacked folder: sudo ./install.sh
# Remove it: sudo ./install.sh --uninstall   (keeps the data; add --purge to delete it)
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo $0 $*"; exit 1; }

HOME_DIR=/opt/gundil-update-server
CONF=/etc/gundil-update-server.conf
DATA=/var/lib/gundil-update-server

if [ "$1" = "--uninstall" ]; then
	systemctl disable --now gundil-update-server 2>/dev/null || true
	rm -f /etc/systemd/system/gundil-update-server.service /usr/local/bin/gundil-update-server \
		/usr/local/sbin/gundil-reset-portal
	rm -rf "$HOME_DIR"
	systemctl daemon-reload
	if [ "$2" = "--purge" ]; then
		rm -rf "$DATA" "$CONF"
		userdel gundil-update 2>/dev/null || true
		echo "Removed, with its data."
	else
		echo "Removed. The data ($DATA) and $CONF are kept; --uninstall --purge deletes them."
	fi
	exit 0
fi

id gundil-update >/dev/null 2>&1 ||
	useradd --system --no-create-home --shell /usr/sbin/nologin gundil-update
mkdir -p "$HOME_DIR"
install -m 755 gundil-update-server "$HOME_DIR/gundil-update-server"
rm -rf "$HOME_DIR/web"
cp -r web "$HOME_DIR/web"
chmod -R a+rX "$HOME_DIR/web"
# The service user owns its folder, so Server tab → Update can replace the
# program and the web page.
chown -R gundil-update: "$HOME_DIR"
ln -sf "$HOME_DIR/gundil-update-server" /usr/local/bin/gundil-update-server
# A root-owned copy, not in the folder the service user may change.
rm -f /usr/local/sbin/gundil-reset-portal "$HOME_DIR/reset-portal.sh"
install -m 755 -o root -g root reset-portal.sh /usr/local/sbin/gundil-reset-portal
[ -f "$CONF" ] || install -m 644 server.conf.example "$CONF"
install -m 644 gundil-update-server.service /etc/systemd/system/gundil-update-server.service
systemctl daemon-reload
systemctl enable gundil-update-server >/dev/null 2>&1
systemctl restart gundil-update-server
sleep 2
echo
echo "Installed and running. Open the web page and sign in as \"admin\":"
journalctl -u gundil-update-server --no-pager -n 30 | grep -E 'web page on|one-time password|\*\*\*' || true
if [ -f "$DATA/initial-password.txt" ]; then
	echo "One-time password: $(cat "$DATA/initial-password.txt")  (you must change it at the first sign-in)"
fi
echo "Log: journalctl -u gundil-update-server -f"
