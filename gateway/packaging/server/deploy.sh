#!/bin/sh
# Deploys the Gundil update server (back end + web front end) from this
# computer to a server over SSH: a Linux box (x86_64, Raspberry Pi, Orange
# Pi; systemd), an OpenWrt router (opkg or apk), or a Windows PC (with the
# OpenSSH server; run as an administrator account).
#
#   ./deploy.sh root@192.168.1.1                 install or upgrade
#   ./deploy.sh --web-only pi@192.168.1.20       only the web page files (./web)
#   ./deploy.sh --package FILE user@host         a package you already have
#   ./deploy.sh --version 1.9.2 user@host        another release
#
# Without --package it uses a matching server package in this folder, or
# downloads it from the GitHub release. Runs on Linux, macOS, WSL or Git Bash.
set -eu

VERSION=@VERSION@
REPO=${GUNDIL_REPO:-monarsh/Gundil-Intercom}
HERE=$(cd "$(dirname "$0")" && pwd)
WEB_ONLY=0
PKG=
TARGET=

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
	case "$1" in
	--web-only) WEB_ONLY=1 ;;
	--package) PKG=${2:?}; shift ;;
	--version) VERSION=${2:?}; shift ;;
	-h|--help) usage ;;
	-*) echo "Unknown option $1"; usage ;;
	*) TARGET=$1 ;;
	esac
	shift
done
[ -n "$TARGET" ] || usage
case "$VERSION" in @*) VERSION= ;; esac

say() { printf '==> %s\n' "$*"; }
remote() { ssh -o ConnectTimeout=10 "$TARGET" "$@"; }

say "Looking at $TARGET"
INFO=$(remote 'uname -sm 2>/dev/null || ver' 2>/dev/null) || { echo "Cannot reach $TARGET over SSH"; exit 1; }
KIND=linux
case "$INFO" in
*Windows*) KIND=windows ;;
*)
	if remote 'test -f /etc/openwrt_release' 2>/dev/null; then KIND=openwrt; fi
	;;
esac

case "$KIND" in
windows)
	ARCH=$(remote 'echo %PROCESSOR_ARCHITECTURE%' | tr -d '\r')
	case "$ARCH" in ARM64) VARIANT=windows-arm64.zip ;; *) VARIANT=windows-x86_64.zip ;; esac
	;;
openwrt)
	if remote 'command -v apk >/dev/null'; then PM=apk; EXT=apk; FAM=openwrt25; else PM=opkg; EXT=ipk; FAM=openwrt; fi
	PARCH=$(remote "$PM --print-arch 2>/dev/null || opkg print-architecture 2>/dev/null | tail -n 1" || true)
	case "$PARCH" in
	*aarch64*) A=aarch64 ;; *mipsel*) A=mipsel ;; *mips*) A=mips ;; *x86_64*) A=x86_64 ;; *arm*) A=arm ;;
	*) case "$INFO" in *aarch64*) A=aarch64 ;; *x86_64*) A=x86_64 ;; *armv7*) A=arm ;; *) echo "Unknown router CPU: $INFO $PARCH"; exit 1 ;; esac ;;
	esac
	VARIANT=$FAM-$A.$EXT
	;;
linux)
	case "$INFO" in
	*x86_64*) A=x86_64 ;; *aarch64*|*arm64*) A=arm64 ;; *armv7*) A=armv7 ;; *armv6*) A=armv6 ;;
	*mips*) A=mipsle; remote 'printf I | od -An -tx1 | grep -q 49' || A=mips ;;
	*) echo "Unknown CPU: $INFO"; exit 1 ;;
	esac
	VARIANT=linux-$A.tar.gz
	;;
esac
say "$KIND server ($INFO)"

# ---------------------------------------------------------------- web only
if [ "$WEB_ONLY" = 1 ]; then
	WEB=$HERE/web
	[ -f "$WEB/index.html" ] || { echo "No web/index.html next to this script"; exit 1; }
	say "Copying the web page files"
	case "$KIND" in
	linux)
		tar -C "$WEB" -czf - . | remote 'sudo sh -c "mkdir -p /opt/gundil-update-server/web && tar -C /opt/gundil-update-server/web -xzf - && chmod -R a+rX /opt/gundil-update-server/web"' ;;
	openwrt)
		tar -C "$WEB" -czf - . | remote 'mkdir -p /www/gundil-update-server && tar -C /www/gundil-update-server -xzf -' ;;
	windows)
		scp -r -q "$WEB/." "$TARGET:C:/Program Files/Gundil Update Server/web/" ;;
	esac
	say "Done (no restart needed; reload the page)."
	exit 0
fi

# -------------------------------------------------------------- the package
if [ -z "$PKG" ]; then
	for dir in "$HERE" .; do
		for f in "$dir"/server-gundil-update-server-*-"$VARIANT" "$dir"/gundil-update-server-*-"$VARIANT"; do
			[ -f "$f" ] || continue
			case "$f" in *-"${VERSION:-}"-"$VARIANT") PKG=$f; break 2 ;; esac
			[ -z "$VERSION" ] && { PKG=$f; break 2; }
		done
	done
fi
if [ -z "$PKG" ]; then
	[ -n "$VERSION" ] || { echo "Say which release: --version 1.9.1"; exit 1; }
	NAME=server-gundil-update-server-$VERSION-$VARIANT
	PKG=${TMPDIR:-/tmp}/$NAME
	say "Downloading $NAME"
	curl -fL --progress-bar -o "$PKG" "https://github.com/$REPO/releases/download/v$VERSION/$NAME"
fi
say "Package: $(basename "$PKG")"

case "$KIND" in
linux)
	say "Uploading and installing (asks for the sudo password if needed)"
	remote 'cat > /tmp/gundil-update-server.tar.gz' < "$PKG"
	ssh -t "$TARGET" 'set -e; d=$(mktemp -d); tar -C "$d" -xzf /tmp/gundil-update-server.tar.gz;
		cd "$d"/gundil-update-server-*; sudo ./install.sh; rm -rf "$d" /tmp/gundil-update-server.tar.gz'
	;;
openwrt)
	say "Uploading and installing"
	remote "cat > /tmp/gundil-update-server.$EXT" < "$PKG"
	if [ "$PM" = apk ]; then
		remote "apk add --allow-untrusted /tmp/gundil-update-server.$EXT"
	else
		remote "opkg install --force-reinstall /tmp/gundil-update-server.$EXT"
	fi
	remote "rm -f /tmp/gundil-update-server.$EXT; /etc/init.d/gundil-update-server enable; /etc/init.d/gundil-update-server restart; sleep 2;
		logread -e gundil-update-server | tail -n 12;
		[ -f /etc/gundil-update-server/initial-password.txt ] && echo \"One-time password: \$(cat /etc/gundil-update-server/initial-password.txt)\" || true"
	;;
windows)
	say "Uploading and installing (the SSH account must be an administrator)"
	scp -q "$PKG" "$TARGET:gundil-update-server.zip"
	remote 'powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference=''Stop'';
		$d=''C:\Program Files\Gundil Update Server'';
		$s=Get-Service GundilUpdateServer -ErrorAction SilentlyContinue; if ($s) { Stop-Service GundilUpdateServer };
		$t=Join-Path $env:TEMP ''gus''; Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue;
		Expand-Archive -Force gundil-update-server.zip $t;
		$src=(Get-ChildItem $t -Directory)[0].FullName;
		New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item -Recurse -Force (Join-Path $src ''*'') $d;
		Remove-Item gundil-update-server.zip;
		if ($s) { Start-Service GundilUpdateServer } else { & (Join-Path $d ''gundil-update-server.exe'') install };
		Start-Sleep 2;
		$p=Join-Path $env:ProgramData ''Gundil\update-server\initial-password.txt'';
		if (Test-Path $p) { Write-Host (''One-time password: '' + (Get-Content $p)) }"'
	;;
esac
say "Done. Open http://<server address>:8780 and sign in as \"admin\"."
