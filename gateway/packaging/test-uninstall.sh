#!/bin/sh
# Tests uninstall-gateway.sh and server/uninstall.sh against fake devices:
# a stub ssh runs the remote commands under a temporary root, with stub
# apk, uci, sudo, systemctl and userdel. Run: sh packaging/test-uninstall.sh
set -eu
P=$(cd "$(dirname "$0")" && pwd)
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/stubs"
export ROOT="$S/root" STUBS="$S/stubs"

cat > "$S/bin/ssh" <<'EOF'
#!/bin/sh
while [ $# -gt 1 ]; do shift; done
cmd=$(printf '%s' "$1" | sed -e "s#/etc/#$ROOT/etc/#g" -e "s#/var/#$ROOT/var/#g" \
	-e "s#/opt/#$ROOT/opt/#g" -e "s#/usr/local/#$ROOT/usr/local/#g" -e "s#/www/#$ROOT/www/#g")
PATH="$STUBS:$PATH" sh -c "$cmd"
EOF
cat > "$S/stubs/apk" <<'EOF'
#!/bin/sh
case "$1" in
info) grep -qx "$3" "$ROOT/pkgs" ;;
del) grep -vx "$2" "$ROOT/pkgs" > "$ROOT/p2" || true; mv "$ROOT/p2" "$ROOT/pkgs" ;;
esac
EOF
printf '#!/bin/sh\necho /etc/gundil-update-server\n' > "$S/stubs/uci"
printf '#!/bin/sh\nexec "$@"\n' > "$S/stubs/sudo"
printf '#!/bin/sh\n:\n' > "$S/stubs/systemctl"
printf '#!/bin/sh\n:\n' > "$S/stubs/userdel"
chmod +x "$S/bin/ssh" "$S/stubs/"*

fail() { echo "FAIL: $*"; exit 1; }
has() { [ -e "$ROOT/$1" ] || fail "$2: $1 is missing"; }
gone() { [ ! -e "$ROOT/$1" ] || fail "$2: $1 is still there"; }
run() { PATH="$S/bin:$PATH" sh "$@" >/dev/null; }

openwrt() {
	rm -rf "$ROOT"
	mkdir -p "$ROOT/etc/config" "$ROOT/etc/init.d" "$ROOT/www/gundil-update-server" \
		"$ROOT/etc/gundil-update-server" "$ROOT/etc/gundil-gateway"
	touch "$ROOT/etc/openwrt_release" "$ROOT/etc/config/gundil" "$ROOT/etc/config/gundil-update" \
		"$ROOT/etc/gundil-gateway/state.json" "$ROOT/etc/gundil-update-server/keys.json"
	printf 'luci-app-gundil-gateway\ngundil-gateway\ngundil-update-server\nluci-app-gundil-update-server\n' > "$ROOT/pkgs"
	for n in gundil-gateway gundil-update-server; do
		printf '#!/bin/sh\n:\n' > "$ROOT/etc/init.d/$n"
		chmod +x "$ROOT/etc/init.d/$n"
	done
	printf '#!/bin/sh\necho "Linux aarch64"\n' > "$STUBS/uname"
	chmod +x "$STUBS/uname"
}
linux() {
	rm -rf "$ROOT"
	mkdir -p "$ROOT/etc/systemd/system" "$ROOT/opt/gundil-gateway" "$ROOT/opt/gundil-update-server" \
		"$ROOT/var/lib/gundil-gateway" "$ROOT/var/lib/gundil-update-server" "$ROOT/usr/local/bin" "$ROOT/usr/local/sbin"
	for f in etc/systemd/system/gundil-gateway.service etc/systemd/system/gundil-update-server.service \
		etc/gundil-gateway.conf etc/gundil-update-server.conf usr/local/bin/gundil-gateway \
		usr/local/bin/gundil-update-server usr/local/sbin/gundil-reset-portal var/lib/gundil-update-server/keys.json; do
		touch "$ROOT/$f"
	done
	printf '#!/bin/sh\necho "Linux x86_64"\n' > "$STUBS/uname"
	chmod +x "$STUBS/uname"
}

openwrt; run "$P/uninstall-gateway.sh" -y root@r
grep -q gundil-gateway "$ROOT/pkgs" && fail "openwrt gateway: package left"
grep -qx gundil-update-server "$ROOT/pkgs" || fail "openwrt gateway: removed the update server"
has etc/config/gundil "openwrt gateway keep"; has etc/gundil-gateway/state.json "openwrt gateway keep"

openwrt; run "$P/uninstall-gateway.sh" -y --purge root@r
gone etc/config/gundil "openwrt gateway purge"; gone etc/gundil-gateway "openwrt gateway purge"
has etc/config/gundil-update "openwrt gateway purge"; has etc/gundil-update-server/keys.json "openwrt gateway purge"

openwrt; run "$P/server/uninstall.sh" -y root@r
grep -q update-server "$ROOT/pkgs" && fail "openwrt server: package left"
grep -qx gundil-gateway "$ROOT/pkgs" || fail "openwrt server: removed the gateway"
has etc/gundil-update-server/keys.json "openwrt server keep"; gone www/gundil-update-server "openwrt server keep"

openwrt; run "$P/server/uninstall.sh" -y --purge root@r
gone etc/gundil-update-server "openwrt server purge"; gone etc/config/gundil-update "openwrt server purge"
has etc/config/gundil "openwrt server purge"

linux; run "$P/uninstall-gateway.sh" -y pi@x
gone opt/gundil-gateway "linux gateway"; gone etc/systemd/system/gundil-gateway.service "linux gateway"
gone usr/local/bin/gundil-gateway "linux gateway"; has etc/gundil-gateway.conf "linux gateway keep"
has opt/gundil-update-server "linux gateway"; has usr/local/bin/gundil-update-server "linux gateway"

linux; run "$P/uninstall-gateway.sh" -y --purge pi@x
gone etc/gundil-gateway.conf "linux gateway purge"; gone var/lib/gundil-gateway "linux gateway purge"
has etc/gundil-update-server.conf "linux gateway purge"

linux; run "$P/server/uninstall.sh" -y pi@x
gone opt/gundil-update-server "linux server"; gone usr/local/sbin/gundil-reset-portal "linux server"
has var/lib/gundil-update-server/keys.json "linux server keep"; has opt/gundil-gateway "linux server"

linux; run "$P/server/uninstall.sh" -y --purge pi@x
gone var/lib/gundil-update-server "linux server purge"; gone etc/gundil-update-server.conf "linux server purge"
has etc/gundil-gateway.conf "linux server purge"

# Without -y it asks, and "no" removes nothing.
linux
if echo n | PATH="$S/bin:$PATH" sh "$P/uninstall-gateway.sh" pi@x >/dev/null 2>&1; then fail "answered no, but it went on"; fi
has opt/gundil-gateway "answered no"

echo "uninstall scripts: all passed"
