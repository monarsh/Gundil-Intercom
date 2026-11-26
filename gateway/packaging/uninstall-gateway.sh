#!/bin/sh
# Removes gundil-gateway from a device over SSH, from this computer: an
# OpenWrt router (with its LuCI page), a Linux box (systemd) or a Windows PC
# (OpenSSH server; an administrator account). The opposite of
# gundil-gateway-deploy.sh.
#
#   ./app-gundil-gateway-uninstall.sh root@192.168.1.1          remove it, keep its settings
#   ./app-gundil-gateway-uninstall.sh --purge root@192.168.1.1  ...and delete its settings
#                                                           and state (web page account,
#                                                           home key, password)
#   -y, --yes      don't ask before removing
#
# Kept without --purge: the settings (OpenWrt /etc/config/gundil, Linux
# /etc/gundil-gateway.conf, Windows %ProgramData%\Gundil\gateway.conf) and the
# state next to them, so deploying again picks up where it left off. An
# update server on the same device is not touched.
# Runs on Linux, macOS, WSL or Git Bash.
set -eu

TARGET=
PURGE=0
YES=0
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
	case "$1" in
	--purge) PURGE=1 ;;
	-y|--yes) YES=1 ;;
	-h|--help) usage ;;
	-*) echo "Unknown option $1"; usage ;;
	*) TARGET=$1 ;;
	esac
	shift
done
[ -n "$TARGET" ] || usage

say() { printf '==> %s\n' "$*"; }
remote() { ssh -o ConnectTimeout=10 "$TARGET" "$@"; }

say "Looking at $TARGET"
INFO=$(remote 'uname -sm 2>/dev/null || ver' 2>/dev/null) || { echo "Cannot reach $TARGET over SSH"; exit 1; }
KIND=linux
case "$INFO" in
*Windows*) KIND=windows ;;
*) if remote 'test -f /etc/openwrt_release' 2>/dev/null; then KIND=openwrt; fi ;;
esac
say "$KIND device ($INFO)"

if [ "$YES" = 0 ]; then
	if [ "$PURGE" = 1 ]; then
		what="gundil-gateway AND its settings and state (home key, password, web page account)"
	else
		what="gundil-gateway (its settings are kept)"
	fi
	printf 'Remove %s from %s? [y/N] ' "$what" "$TARGET"
	read -r ans
	case "$ans" in y|Y|yes) ;; *) echo "Nothing removed."; exit 1 ;; esac
fi

case "$KIND" in
openwrt)
	remote "set -u
		if command -v apk >/dev/null; then PM=apk; else PM=opkg; fi
		[ -x /etc/init.d/gundil-gateway ] && { /etc/init.d/gundil-gateway stop; /etc/init.d/gundil-gateway disable; } 2>/dev/null
		found=0
		for p in luci-app-gundil-gateway gundil-gateway; do
			if [ \$PM = apk ]; then
				apk info -e \$p >/dev/null 2>&1 && { apk del \$p; found=1; }
			else
				opkg status \$p 2>/dev/null | grep -q '^Status:.* installed' && { opkg remove \$p; found=1; }
			fi
		done
		[ \$found = 1 ] && echo 'Removed the packages.' || echo 'gundil-gateway was not installed.'
		rm -f /var/etc/gundil-gateway.conf
		if [ $PURGE = 1 ]; then
			rm -rf /etc/config/gundil /etc/gundil-gateway /etc/config/gundil-opkg /etc/config/gundil.apk-new
			echo 'Deleted the settings and state.'
		else
			echo 'Kept the settings: /etc/config/gundil (and the state in /etc/gundil-gateway).'
		fi
		rm -f /tmp/luci-indexcache* 2>/dev/null; true"
	;;
linux)
	say "Removing (asks for the sudo password if needed)"
	ssh -t "$TARGET" "set -u
		sudo systemctl disable --now gundil-gateway 2>/dev/null || true
		if [ -e /etc/systemd/system/gundil-gateway.service ] || [ -d /opt/gundil-gateway ]; then
			echo 'Removed the service and the program.'
		else
			echo 'gundil-gateway was not installed.'
		fi
		sudo rm -f /etc/systemd/system/gundil-gateway.service /usr/local/bin/gundil-gateway
		sudo rm -rf /opt/gundil-gateway
		sudo systemctl daemon-reload
		if [ $PURGE = 1 ]; then
			sudo rm -rf /etc/gundil-gateway.conf /var/lib/gundil-gateway
			sudo userdel gundil-gateway 2>/dev/null || true
			echo 'Deleted the settings and state.'
		else
			echo 'Kept the settings: /etc/gundil-gateway.conf and the state in /var/lib/gundil-gateway.'
		fi"
	;;
windows)
	remote 'powershell -NoProfile -ExecutionPolicy Bypass -Command "
		$d=''C:\Program Files\Gundil Gateway''; $exe=Join-Path $d ''gundil-gateway.exe'';
		$g=Join-Path $env:ProgramData ''Gundil'';
		if (Get-Service GundilGateway -ErrorAction SilentlyContinue) {
			if (Test-Path $exe) { & $exe uninstall } else { Stop-Service GundilGateway -ErrorAction SilentlyContinue; sc.exe delete GundilGateway | Out-Null };
			Write-Host ''Removed the GundilGateway service.'' }
		else { Write-Host ''The GundilGateway service was not installed.'' };
		Start-Sleep 1;
		Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue;
		if (Test-Path $d) { Write-Host (''Could not delete '' + $d + '' (in use?); delete it by hand.'') } else { Write-Host (''Deleted '' + $d) };
		if ('"$PURGE"' -eq 1) {
			foreach ($f in @(''gateway.conf'',''gateway-state.json'',''web-admin.json'',''web-initial-password.txt'')) {
				Remove-Item -Force (Join-Path $g $f) -ErrorAction SilentlyContinue };
			if ((Test-Path $g) -and -not (Get-ChildItem $g -Force)) { Remove-Item $g };
			Write-Host ''Deleted the settings and state.'' }
		else { Write-Host (''Kept the settings: '' + (Join-Path $g ''gateway.conf'')) }"'
	;;
esac
say "Done."
