#!/bin/sh
# Builds every gundil-update-server package into ../dist-server:
#   Linux tarballs (install.sh + systemd: PC, Raspberry Pi, Orange Pi),
#   OpenWrt .ipk, Windows zips, and the deploy/reset tools.
# The OpenWrt 25 .apk and the AppImages are made by mkapk.sh and
# server/build_appimage.sh from what this leaves in build/.
# Usage: packaging/build-server.sh VERSION
set -e
VERSION=${1:?version}
RELEASE_KEY=${2:-} # Checks the signatures of the releases it imports (release_sig.go).
cd "$(dirname "$0")/.."
DIST=dist-server
STAGE=build/apk-server
rm -rf "$DIST" "$STAGE" build/server-bin && mkdir -p "$DIST" "$STAGE" build/server-bin
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
S=packaging/server

build() { # os arch arm out
	CGO_ENABLED=0 GOOS=$1 GOARCH=$2 GOARM=$3 GOMIPS=softfloat \
		go build -tags updateserver -trimpath -ldflags "-s -w -X main.version=$VERSION -X main.releaseKey=$RELEASE_KEY" -o "$4" .
}

conf_example() {
	sed -n '/^const serverConfigTemplate = `/,/^`$/p' server_config.go | sed '1s/^const serverConfigTemplate = `//;$d' > "$1"
}

tools() { # dir: the scripts that work from the admin's computer or the server
	sed "s/@VERSION@/$VERSION/" $S/deploy.sh > "$1/deploy.sh"
	chmod 755 "$1/deploy.sh"
	install -m 755 $S/reset-portal.sh "$1/reset-portal.sh"
	cp $S/README.txt "$1/README.txt"
}

# Linux tarballs.
for t in x86_64:amd64: arm64:arm64: armv7:arm:7 armv6:arm:6 mipsle:mipsle: mips:mips:; do
	IFS=: read name arch arm <<-X
	$t
	X
	d="$TMP/gundil-update-server-$VERSION-linux-$name"
	mkdir -p "$d"
	build linux "$arch" "$arm" "$d/gundil-update-server"
	cp "$d/gundil-update-server" "build/server-bin/linux-$name"
	cp -r web "$d/web"
	install -m 755 $S/install.sh "$d/install.sh"
	cp $S/gundil-update-server.service "$d/"
	conf_example "$d/server.conf.example"
	tools "$d"
	(cd "$TMP" && tar czf "$OLDPWD/$DIST/gundil-update-server-$VERSION-linux-$name.tar.gz" \
		--owner=0 --group=0 "gundil-update-server-$VERSION-linux-$name")
done

# OpenWrt packages (one static binary per CPU family).
for t in aarch64:linux-arm64 arm:linux-armv7 mipsel:linux-mipsle mips:linux-mips x86_64:linux-x86_64; do
	IFS=: read name from <<-X
	$t
	X
	p="$TMP/ipk-$name"
	mkdir -p "$p/data/usr/bin" "$p/data/usr/sbin" "$p/data/etc/init.d" "$p/data/etc/config" \
		"$p/data/www/gundil-update-server" "$p/control"
	cp "build/server-bin/$from" "$p/data/usr/bin/gundil-update-server"
	install -m 755 $S/reset-portal.sh "$p/data/usr/sbin/gundil-reset-portal"
	install -m 755 $S/gundil-update-server.init "$p/data/etc/init.d/gundil-update-server"
	install -m 600 $S/gundil-update.config "$p/data/etc/config/gundil-update"
	cp -r web/. "$p/data/www/gundil-update-server/"
	size=$(du -sk "$p/data" | cut -f1)
	cat > "$p/control/control" <<-C
	Package: gundil-update-server
	Version: $VERSION
	Architecture: all
	Maintainer: Gundil Intercom
	Installed-Size: $((size * 1024))
	Description: Update server for Gundil Intercom: tells the apps worldwide which version to install, through STUN + UDP hole punching (no public IP). Admin web page on port 8780. Build for $name CPUs.
	C
	mkdir -p "$STAGE/$name" && cp -a "$p/data/." "$STAGE/$name/"
	echo /etc/config/gundil-update > "$p/control/conffiles"
	printf '#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || { /etc/init.d/gundil-update-server enable; /etc/init.d/gundil-update-server restart; }\nexit 0\n' > "$p/control/postinst"
	printf '#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || { /etc/init.d/gundil-update-server stop; /etc/init.d/gundil-update-server disable; }\nexit 0\n' > "$p/control/prerm"
	chmod 755 "$p/control/postinst" "$p/control/prerm"
	echo 2.0 > "$p/debian-binary"
	(cd "$p/control" && tar czf ../control.tar.gz --owner=0 --group=0 .)
	(cd "$p/data" && tar czf ../data.tar.gz --owner=0 --group=0 .)
	(cd "$p" && tar czf "$OLDPWD/$DIST/gundil-update-server-$VERSION-openwrt-$name.ipk" \
		--owner=0 --group=0 ./debian-binary ./control.tar.gz ./data.tar.gz)
done

# LuCI page (Services → Gundil update server), the same for every CPU.
p="$TMP/ipk-luci"
mkdir -p "$p/data/www/luci-static/resources/view" "$p/data/usr/share/luci/menu.d" \
	"$p/data/usr/share/rpcd/acl.d" "$p/data/usr/libexec" "$p/control"
install -m 644 $S/luci/gundil-update-server.js "$p/data/www/luci-static/resources/view/gundil-update-server.js"
install -m 644 $S/luci/menu.json "$p/data/usr/share/luci/menu.d/luci-app-gundil-update-server.json"
install -m 644 $S/luci/acl.json "$p/data/usr/share/rpcd/acl.d/luci-app-gundil-update-server.json"
install -m 755 $S/luci/gundil-update-server-luci "$p/data/usr/libexec/gundil-update-server-luci"
mkdir -p "$STAGE/luci" && cp -a "$p/data/." "$STAGE/luci/"
size=$(du -sk "$p/data" | cut -f1)
cat > "$p/control/control" <<-C
Package: luci-app-gundil-update-server
Version: $VERSION
Depends: gundil-update-server, luci-base
Architecture: all
Maintainer: Gundil Intercom
Installed-Size: $((size * 1024))
Description: LuCI page for gundil-update-server: Services, Gundil update server (status, server code, admin page link, settings, log, restart, reset portal).
C
printf '#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || { rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null; /etc/init.d/rpcd reload; }\nexit 0\n' > "$p/control/postinst"
printf '#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || rm -f /tmp/luci-indexcache* 2>/dev/null\nexit 0\n' > "$p/control/postrm"
chmod 755 "$p/control/postinst" "$p/control/postrm"
echo 2.0 > "$p/debian-binary"
(cd "$p/control" && tar czf ../control.tar.gz --owner=0 --group=0 .)
(cd "$p/data" && tar czf ../data.tar.gz --owner=0 --group=0 .)
(cd "$p" && tar czf "$OLDPWD/$DIST/gundil-update-server-$VERSION-openwrt-luci.ipk" \
	--owner=0 --group=0 ./debian-binary ./control.tar.gz ./data.tar.gz)

# Windows (a service: gundil-update-server.exe install).
for t in x86_64:amd64 arm64:arm64; do
	IFS=: read name arch <<-X
	$t
	X
	d="$TMP/gundil-update-server-$VERSION-windows-$name"
	mkdir -p "$d"
	build windows "$arch" "" "$d/gundil-update-server.exe"
	cp -r web "$d/web"
	cp $S/reset-portal.ps1 "$d/"
	conf_example "$d/server.conf.example"
	cp $S/README.txt "$d/README.txt"
	(cd "$TMP" && zip -qr "$OLDPWD/$DIST/gundil-update-server-$VERSION-windows-$name.zip" \
		"gundil-update-server-$VERSION-windows-$name")
done

# The admin tools on their own (deploy from your computer).
d="$TMP/gundil-update-server-$VERSION-tools"
mkdir -p "$d"
tools "$d"
cp $S/reset-portal.ps1 "$d/"
cp -r web "$d/web"
(cd "$TMP" && zip -qr "$OLDPWD/$DIST/gundil-update-server-$VERSION-tools.zip" "gundil-update-server-$VERSION-tools")
ls -la "$DIST"
