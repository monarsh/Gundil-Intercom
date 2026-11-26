#!/bin/sh
# Deploys gundil-gateway from this computer to a device over SSH: an OpenWrt
# router (opkg or apk; with the LuCI page when the router has LuCI), a Linux
# box (x86_64, Raspberry Pi, Orange Pi; systemd), or a Windows PC (with the
# OpenSSH server; run as an administrator account).
#
#   ./deploy-gateway.sh root@192.168.1.1              install or upgrade
#   ./deploy-gateway.sh --home-key root@192.168.1.1   ...and set the home key
#   ./deploy-gateway.sh --version 1.9.2 user@host     a given release
#   ./deploy-gateway.sh --package FILE user@host      a package you already have
#
# Settings (optional; existing settings are kept unless given):
#   --home-key           asks for the home key (GUNDIL-PAIR-..., from a paired
#                        app: Settings > Internet calls > Pairing > Copy)
#   --password           asks for the intercom password (10+ characters)
#   --name NAME          the name the apps show
#   --share-cameras yes|no
#   --update-server CODE the update server's code (GUNDIL-UPDATE-...)
#   --no-check           don't run the network check at the end
# The home key and password are asked for (not typed on the command line, so
# they stay out of your shell history), or read from GUNDIL_HOME_KEY /
# GUNDIL_PASSWORD.
#
# Without --package it uses a matching package in this folder, or downloads
# it from the GitHub release (the newest one unless --version is given).
# Runs on Linux, macOS, WSL or Git Bash.
set -eu

VERSION=@VERSION@
REPO=${GUNDIL_REPO:-monarsh/Gundil-Intercom}
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=
TARGET=
CHECK=1
SET=$(mktemp)
trap 'rm -f "$SET"' EXIT

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ask_secret() { # prompt -> value on stdout
	printf '%s: ' "$1" >&2
	stty -echo 2>/dev/null || true
	IFS= read -r v || true
	stty echo 2>/dev/null || true
	echo >&2
	printf '%s' "$v"
}
put() { # key value: one setting for the device
	case "$2" in *'
'*) echo "A setting can't have a line break"; exit 1 ;; esac
	printf '%s=%s\n' "$1" "$2" >> "$SET"
}

while [ $# -gt 0 ]; do
	case "$1" in
	--home-key)
		k=${GUNDIL_HOME_KEY:-$(ask_secret "Home key (GUNDIL-PAIR-...)")}
		case "$k" in GUNDIL-PAIR-?*) ;; *) echo "That isn't a home key (it starts with GUNDIL-PAIR-)"; exit 1 ;; esac
		put home_key "$k" ;;
	--password)
		p=${GUNDIL_PASSWORD:-$(ask_secret "Intercom password")}
		[ ${#p} -ge 10 ] || { echo "The intercom password needs 10+ characters"; exit 1; }
		put password "$p" ;;
	--name) put name "${2:?}"; shift ;;
	--share-cameras)
		case "${2:?}" in yes|true|1) put share_cameras 1 ;; no|false|0) put share_cameras 0 ;;
		*) echo "--share-cameras yes or no"; exit 2 ;; esac
		shift ;;
	--update-server)
		case "${2:?}" in GUNDIL-UPDATE-?*) ;; *) echo "That isn't a server code (GUNDIL-UPDATE-...)"; exit 1 ;; esac
		put update_server "$2"; shift ;;
	--no-check) CHECK=0 ;;
	--package) PKG=${2:?}; shift ;;
	--version) VERSION=${2#v}; shift ;;
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
*) if remote 'test -f /etc/openwrt_release' 2>/dev/null; then KIND=openwrt; fi ;;
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
say "$KIND device ($INFO)"

# ------------------------------------------------------------- the package
find_local() { # name-suffix -> path of a matching local file
	for dir in "$HERE" .; do
		for f in "$dir"/app-gundil-gateway-*-"$1" "$dir"/gundil-gateway-*-"$1"; do
			[ -f "$f" ] || continue
			case "$f" in *-"${VERSION:-}"-"$1") echo "$f"; return ;; esac
			[ -z "$VERSION" ] && { echo "$f"; return; }
		done
	done
	return 0
}
fetch() { # name -> downloaded path
	out=${TMPDIR:-/tmp}/$1
	curl -fL --progress-bar -o "$out" "https://github.com/$REPO/releases/download/v$VERSION/$1" && echo "$out"
}
[ -n "$PKG" ] || PKG=$(find_local "$VARIANT")
if [ -z "$PKG" ]; then
	if [ -z "$VERSION" ]; then
		VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
			sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)
		[ -n "$VERSION" ] || { echo "Can't find the newest release; say which: --version 1.9.2"; exit 1; }
	fi
	say "Downloading gundil-gateway $VERSION ($VARIANT)"
	PKG=$(fetch "app-gundil-gateway-$VERSION-$VARIANT") || { echo "No such file in release v$VERSION"; exit 1; }
fi
say "Package: $(basename "$PKG")"

# ------------------------------------------------------------- install
case "$KIND" in
openwrt)
	say "Uploading and installing"
	remote "cat > /tmp/gundil-gateway.$EXT" < "$PKG"
	if [ "$PM" = apk ]; then
		remote "apk add --allow-untrusted /tmp/gundil-gateway.$EXT; rm -f /tmp/gundil-gateway.$EXT"
	else
		remote "opkg install --force-reinstall /tmp/gundil-gateway.$EXT; rm -f /tmp/gundil-gateway.$EXT"
	fi
	if remote 'test -d /www/luci-static/resources/view' 2>/dev/null; then
		LPKG=$(find_local "$FAM-luci.$EXT")
		[ -n "$LPKG" ] || [ -z "$VERSION" ] || LPKG=$(fetch "app-gundil-gateway-$VERSION-$FAM-luci.$EXT" 2>/dev/null) || LPKG=
		if [ -n "$LPKG" ]; then
			say "Installing the LuCI page (Services > Gundil gateway)"
			remote "cat > /tmp/gundil-gateway-luci.$EXT" < "$LPKG"
			if [ "$PM" = apk ]; then
				remote "apk add --allow-untrusted /tmp/gundil-gateway-luci.$EXT; rm -f /tmp/gundil-gateway-luci.$EXT"
			else
				remote "opkg install --force-reinstall /tmp/gundil-gateway-luci.$EXT; rm -f /tmp/gundil-gateway-luci.$EXT"
			fi
		fi
	fi
	if [ -s "$SET" ]; then
		say "Saving the settings"
		remote 'umask 077; cat > /tmp/gundil-gateway.set' < "$SET"
		remote 'while IFS="=" read -r k v; do uci set "gundil.main.$k=$v"; done < /tmp/gundil-gateway.set;
			rm -f /tmp/gundil-gateway.set; uci commit gundil'
	fi
	remote '/etc/init.d/gundil-gateway enable; /etc/init.d/gundil-gateway restart; sleep 3;
		logread -e gundil-gateway | tail -n 10'
	[ "$CHECK" = 0 ] || { say "Network check (about 10 s)"; remote 'gundil-gateway --check --config=/var/etc/gundil-gateway.conf' || true; }
	;;
linux)
	say "Uploading and installing (asks for the sudo password if needed)"
	remote 'cat > /tmp/gundil-gateway.tar.gz' < "$PKG"
	remote 'umask 077; cat > /tmp/gundil-gateway.set' < "$SET"
	ssh -t "$TARGET" 'set -e; d=$(mktemp -d); tar -C "$d" -xzf /tmp/gundil-gateway.tar.gz;
		cd "$d"/gundil-gateway-*; sudo ./install.sh >/dev/null;
		C=/etc/gundil-gateway.conf
		if [ -s /tmp/gundil-gateway.set ]; then
			while IFS="=" read -r k v; do
				[ "$k" = share_cameras ] && { [ "$v" = 1 ] && v=true || v=false; }
				sudo sh -c "grep -v -E \"^#? *$k *=\" $C > $C.new; printf \"%s = %s\\n\" \"\$0\" \"\$1\" >> $C.new; cat $C.new > $C; rm -f $C.new" "$k" "$v"
			done < /tmp/gundil-gateway.set
		fi
		rm -rf "$d" /tmp/gundil-gateway.tar.gz /tmp/gundil-gateway.set
		if sudo grep -Eq "^(password *= *.{10,}|home_key *= *[^ ]+)" $C; then
			sudo systemctl enable gundil-gateway >/dev/null 2>&1; sudo systemctl restart gundil-gateway; sleep 3
			sudo journalctl -u gundil-gateway -n 10 --no-pager
		else
			echo "Not started: no intercom password or home key yet. Run again with --home-key or --password."
			exit 3
		fi'
	[ "$CHECK" = 0 ] || { say "Network check (about 10 s)"; ssh -t "$TARGET" 'sudo gundil-gateway --check --config=/etc/gundil-gateway.conf' || true; }
	;;
windows)
	say "Uploading and installing (the SSH account must be an administrator)"
	scp -q "$PKG" "$TARGET:gundil-gateway.zip"
	scp -q "$SET" "$TARGET:gundil-gateway.set"
	remote 'powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference=''Stop'';
		$d=''C:\Program Files\Gundil Gateway''; $exe=Join-Path $d ''gundil-gateway.exe'';
		$c=Join-Path $env:ProgramData ''Gundil\gateway.conf'';
		$s=Get-Service GundilGateway -ErrorAction SilentlyContinue; if ($s) { Stop-Service GundilGateway };
		$t=Join-Path $env:TEMP ''ggw''; Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue;
		Expand-Archive -Force gundil-gateway.zip $t;
		$src=(Get-ChildItem $t -Directory)[0].FullName;
		New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item -Recurse -Force (Join-Path $src ''*'') $d;
		Remove-Item gundil-gateway.zip;
		if (-not (Test-Path $c)) { & $exe install | Out-Null };
		$set=Get-Content gundil-gateway.set -ErrorAction SilentlyContinue; Remove-Item gundil-gateway.set;
		if ($set) { $lines=@(Get-Content $c);
			foreach ($kv in $set) { $i=$kv.IndexOf(''=''); $k=$kv.Substring(0,$i); $v=$kv.Substring($i+1);
				if ($k -eq ''share_cameras'') { if ($v -eq ''1'') { $v=''true'' } else { $v=''false'' } };
				$lines=@($lines | Where-Object { $_ -notmatch (''^#?\s*''+$k+''\s*='') }) + (''{0} = {1}'' -f $k,$v) };
			Set-Content -Path $c -Value $lines };
		if ($s) { Start-Service GundilGateway; Write-Host ''Restarted the GundilGateway service.'' }
		else { & $exe install };
		if ('"$CHECK"' -eq 1) { Write-Host ''Network check (about 10 s)''; & $exe --check --config=$c }"'
	;;
esac
say "Done."
