#!/bin/sh
# Builds every gundil-gateway package into ../dist:
#   linux tarballs (install.sh + systemd), OpenWrt .ipk, Windows zips.
# Usage: packaging/build.sh VERSION
set -e
VERSION=${1:?version}
cd "$(dirname "$0")/.."
DIST=dist
rm -rf "$DIST" && mkdir -p "$DIST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

build() { # os arch arm out
	CGO_ENABLED=0 GOOS=$1 GOARCH=$2 GOARM=$3 GOMIPS=softfloat \
		go build -trimpath -ldflags "-s -w -X main.version=$VERSION" -o "$4" .
}

conf_example() {
	sed -n '/^const configTemplate = `/,/^`$/p' config.go | sed '1s/^const configTemplate = `//;$d' > "$1"
}

# Linux tarballs.
for t in x86_64:amd64: arm64:arm64: armv7:arm:7 armv6:arm:6 mipsle:mipsle: mips:mips:; do
	IFS=: read name arch arm <<-X
	$t
	X
	d="$TMP/gundil-gateway-$VERSION-linux-$name"
	mkdir -p "$d"
	build linux "$arch" "$arm" "$d/gundil-gateway"
	cp packaging/linux/install.sh packaging/linux/gundil-gateway.service "$d/"
	conf_example "$d/gundil-gateway.conf.example"
	(cd "$TMP" && tar czf "$OLDPWD/$DIST/gundil-gateway-$VERSION-linux-$name.tar.gz" \
		--owner=0 --group=0 "gundil-gateway-$VERSION-linux-$name")
done

# OpenWrt packages (Architecture: all, one static binary per CPU family).
for t in aarch64:linux-arm64 arm:linux-armv7 mipsel:linux-mipsle mips:linux-mips x86_64:linux-x86_64; do
	IFS=: read name from <<-X
	$t
	X
	p="$TMP/ipk-$name"
	mkdir -p "$p/data/usr/bin" "$p/data/etc/init.d" "$p/data/etc/config" "$p/control"
	cp "$TMP/gundil-gateway-$VERSION-$from/gundil-gateway" "$p/data/usr/bin/"
	install -m 755 packaging/openwrt/gundil-gateway.init "$p/data/etc/init.d/gundil-gateway"
	install -m 600 packaging/openwrt/gundil.config "$p/data/etc/config/gundil"
	size=$(du -sk "$p/data" | cut -f1)
	cat > "$p/control/control" <<-C
	Package: gundil-gateway
	Version: $VERSION
	Architecture: all
	Maintainer: Gundil Intercom
	Installed-Size: $((size * 1024))
	Description: Lets the Gundil Intercom apps reach the cameras on this LAN over the internet (STUN + UDP hole punching, public Nostr relays). Build for $name CPUs.
	C
	echo /etc/config/gundil > "$p/control/conffiles"
	printf '#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || /etc/init.d/gundil-gateway enable\nexit 0\n' > "$p/control/postinst"
	printf '#!/bin/sh\n[ -n "$IPKG_INSTROOT" ] || { /etc/init.d/gundil-gateway stop; /etc/init.d/gundil-gateway disable; }\nexit 0\n' > "$p/control/prerm"
	chmod 755 "$p/control/postinst" "$p/control/prerm"
	echo 2.0 > "$p/debian-binary"
	(cd "$p/control" && tar czf ../control.tar.gz --owner=0 --group=0 .)
	(cd "$p/data" && tar czf ../data.tar.gz --owner=0 --group=0 .)
	(cd "$p" && tar czf "$OLDPWD/$DIST/gundil-gateway-$VERSION-openwrt-$name.ipk" \
		--owner=0 --group=0 ./debian-binary ./control.tar.gz ./data.tar.gz)
done

# Windows.
for t in x86_64:amd64 arm64:arm64; do
	IFS=: read name arch <<-X
	$t
	X
	d="$TMP/gundil-gateway-$VERSION-windows-$name"
	mkdir -p "$d"
	build windows "$arch" "" "$d/gundil-gateway.exe"
	conf_example "$d/gateway.conf.example"
	(cd "$TMP" && zip -qr "$OLDPWD/$DIST/gundil-gateway-$VERSION-windows-$name.zip" \
		"gundil-gateway-$VERSION-windows-$name")
done
ls -la "$DIST"
