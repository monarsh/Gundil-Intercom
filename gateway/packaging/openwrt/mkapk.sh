#!/bin/sh
# Packs the OpenWrt file trees from build.sh (build/apk/<name>) into
# OpenWrt 25+ packages (apk v3, unsigned: install with
# "apk add --allow-untrusted"). Needs apk-tools 3 ("apk mkpkg"), e.g. in
# an Alpine 3.23+ container. Usage: packaging/openwrt/mkapk.sh VERSION
set -e
VERSION=${1:?version}
cd "$(dirname "$0")/../.."
STAGE=build/apk
DIST=dist
apk mkpkg --help >/dev/null 2>&1 || {
	echo "mkapk.sh: needs apk-tools 3 (apk mkpkg); this apk is: $(apk --version 2>&1)" >&2
	exit 1
}
# apk wants a version like 1.9.0-r1.
case "$VERSION" in
[0-9]*) APKV="$VERSION-r1" ;;
*) APKV="0.0.0_git-r0" ;;
esac
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
# Pack copies owned by root (the files are installed as root:root).
cp -a "$STAGE" "$S/tree"
chown -R 0:0 "$S/tree" 2>/dev/null || true
STAGE="$S/tree"

# Scripts run on the router (and are harmless anywhere else).
cat > "$S/gw-post-install" <<'X'
#!/bin/sh
[ -f /etc/openwrt_release ] || exit 0
chmod 600 /etc/config/gundil 2>/dev/null
/etc/init.d/gundil-gateway enable
exit 0
X
cat > "$S/gw-post-upgrade" <<'X'
#!/bin/sh
[ -f /etc/openwrt_release ] || exit 0
chmod 600 /etc/config/gundil 2>/dev/null
/etc/init.d/gundil-gateway enabled && /etc/init.d/gundil-gateway restart
exit 0
X
cat > "$S/gw-pre-deinstall" <<'X'
#!/bin/sh
[ -f /etc/openwrt_release ] || exit 0
/etc/init.d/gundil-gateway stop
/etc/init.d/gundil-gateway disable
exit 0
X
cat > "$S/luci-post-install" <<'X'
#!/bin/sh
[ -f /etc/openwrt_release ] || exit 0
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload
exit 0
X
chmod 755 "$S"/*

for name in aarch64 arm mipsel mips x86_64; do
	t="$STAGE/$name"
	[ -d "$t" ] || continue
	# OpenWrt's own package database files (conffiles: kept by sysupgrade).
	mkdir -p "$t/lib/apk/packages"
	echo /etc/config/gundil > "$t/lib/apk/packages/gundil-gateway.conffiles"
	apk mkpkg \
		--info "name:gundil-gateway" \
		--info "version:$APKV" \
		--info "description:Lets the Gundil Intercom apps reach the cameras on this LAN over the internet (STUN + UDP hole punching, public Nostr relays). Static build for $name CPUs." \
		--info "arch:noarch" \
		--info "license:proprietary" \
		--info "origin:gundil-gateway" \
		--info "maintainer:Gundil Intercom" \
		--script "post-install:$S/gw-post-install" \
		--script "post-upgrade:$S/gw-post-upgrade" \
		--script "pre-deinstall:$S/gw-pre-deinstall" \
		--files "$t" \
		--output "$DIST/gundil-gateway-$VERSION-openwrt25-$name.apk"
done

t="$STAGE/luci"
mkdir -p "$t/lib/apk/packages"
apk mkpkg \
	--info "name:luci-app-gundil-gateway" \
	--info "version:$APKV" \
	--info "description:LuCI page for gundil-gateway: Services, Gundil gateway (password or home key, sharing, status, network check, log)." \
	--info "arch:noarch" \
	--info "license:proprietary" \
	--info "origin:luci-app-gundil-gateway" \
	--info "maintainer:Gundil Intercom" \
	--info "depends:gundil-gateway luci-base" \
	--script "post-install:$S/luci-post-install" \
	--script "post-upgrade:$S/luci-post-install" \
	--files "$t" \
	--output "$DIST/gundil-gateway-$VERSION-openwrt25-luci.apk"
ls -la "$DIST"/*.apk
