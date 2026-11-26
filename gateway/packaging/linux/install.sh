#!/bin/sh
# Installs gundil-gateway as a systemd service (Debian, Ubuntu, Raspberry Pi
# OS, Armbian). Run from the unpacked folder: sudo ./install.sh
# To remove it: sudo ./install.sh --uninstall
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo $0 $*"; exit 1; }

CONF=/etc/gundil-gateway.conf
if [ "$1" = "--uninstall" ]; then
	systemctl disable --now gundil-gateway 2>/dev/null || true
	rm -f /etc/systemd/system/gundil-gateway.service /usr/local/bin/gundil-gateway
	rm -rf /opt/gundil-gateway
	systemctl daemon-reload
	userdel gundil-gateway 2>/dev/null || true
	rm -rf /var/lib/gundil-gateway
	echo "Removed. $CONF is kept (delete it yourself if you like)."
	exit 0
fi

id gundil-gateway >/dev/null 2>&1 ||
	useradd --system --no-create-home --shell /usr/sbin/nologin gundil-gateway
# The service may replace its own program (self-update), so it lives in a
# folder the service user owns.
mkdir -p /opt/gundil-gateway
install -m 755 gundil-gateway /opt/gundil-gateway/gundil-gateway
chown -R gundil-gateway:gundil-gateway /opt/gundil-gateway
rm -f /usr/local/bin/gundil-gateway
ln -s /opt/gundil-gateway/gundil-gateway /usr/local/bin/gundil-gateway
if [ ! -f "$CONF" ]; then
	install -m 640 gundil-gateway.conf.example "$CONF"
fi
chown root:gundil-gateway "$CONF"
chmod 640 "$CONF"
install -m 644 gundil-gateway.service /etc/systemd/system/gundil-gateway.service
systemctl daemon-reload
if grep -Eq '^(password *= *.{10,}|home_key *= *[^ ]+)' "$CONF"; then
	systemctl enable --now gundil-gateway
	systemctl restart gundil-gateway
	echo "Running. Check it: gundil-gateway --check --config=$CONF"
	echo "Log: journalctl -u gundil-gateway -f"
else
	systemctl enable gundil-gateway
	echo "Installed. Now set the intercom password (or home_key) in $CONF, then:"
	echo "  sudo systemctl start gundil-gateway"
fi
