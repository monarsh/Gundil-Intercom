#!/bin/sh
# Starts the update server's web portal afresh: the admin account is
# replaced by a new one with a one-time password, which must be changed at
# the first sign-in. Run on the server as root.
#
#   gundil-reset-portal           new admin account (devices, versions kept)
#   gundil-reset-portal --all     also forget devices, policy and versions
#   gundil-reset-portal --all --new-key
#                                 everything, and a new server key: every
#                                 installed app must get the new server code
set -e
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo $0 $*"; exit 1; }
ALL=; KEY=
for a in "$@"; do
	case "$a" in
	--all) ALL=--all ;;
	--new-key) KEY=--new-key ;;
	-y|--yes) YES=1 ;;
	*) echo "Unknown option $a"; exit 2 ;;
	esac
done
if [ -n "$KEY" ] && [ -z "$YES" ]; then
	printf 'A new server key cuts off every installed app until it gets the new server code. Continue? [y/N] '
	read -r ans
	[ "$ans" = y ] || [ "$ans" = Y ] || exit 1
fi

BIN=$(command -v gundil-update-server || echo /usr/bin/gundil-update-server)
if [ -f /etc/openwrt_release ]; then
	CONF=/var/etc/gundil-update-server.conf
	/etc/init.d/gundil-update-server stop 2>/dev/null || true
	[ -f "$CONF" ] || CONF=/dev/null
	"$BIN" --config="$CONF" $ALL $KEY reset-admin
	/etc/init.d/gundil-update-server start
	sleep 2
	echo
	logread -e gundil-update-server | tail -n 8
else
	CONF=/etc/gundil-update-server.conf
	systemctl stop gundil-update-server
	if id gundil-update >/dev/null 2>&1; then
		# As the service user: it owns the program (Update replaces it), so
		# root doesn't run it.
		su -s /bin/sh gundil-update -c "\"$BIN\" --config=\"$CONF\" $ALL $KEY reset-admin"
	else
		"$BIN" --config="$CONF" $ALL $KEY reset-admin
	fi
	systemctl start gundil-update-server
	sleep 2
	echo
	journalctl -u gundil-update-server --no-pager -n 20 | grep -E '\*\*\*' || true
fi
for d in /var/lib/gundil-update-server /etc/gundil-update-server; do
	[ -f "$d/initial-password.txt" ] && echo "One-time password: $(cat "$d/initial-password.txt")"
done
echo "Sign in as \"admin\" with it; you'll be asked to choose a new password."
