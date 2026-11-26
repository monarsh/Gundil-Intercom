#!/bin/sh
# Removes the Gundil update server from a server over SSH, from this
# computer: a Linux box (systemd), an OpenWrt router (with its LuCI page) or
# a Windows PC (OpenSSH server; an administrator account). The opposite of
# deploy.sh.
#
#   ./uninstall.sh pi@192.168.1.20            remove it, keep its data
#   ./uninstall.sh --purge pi@192.168.1.20    ...and delete its data: the server
#                                             key (every app loses the server),
#                                             devices, versions, kept files,
#                                             admin account and settings
#   -y, --yes      don't ask before removing
#
# Kept without --purge: the data folder (Linux /var/lib/gundil-update-server,
# OpenWrt /etc/gundil-update-server, Windows %ProgramData%\Gundil\update-server)
# with the server key, and the settings, so deploying again brings back the
# same server code. A gateway on the same device is not touched.
# Runs on Linux, macOS, WSL or Git Bash.
set -eu

TARGET=
PURGE=0
YES=0
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
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
		echo "--purge deletes the server key: every installed app loses this server for good"
		echo "(a new install makes a new server code), and the devices, versions and kept files."
		what="the update server AND all its data"
	else
		what="the update server (its data and server key are kept)"
	fi
	printf 'Remove %s from %s? [y/N] ' "$what" "$TARGET"
	read -r ans
	case "$ans" in y|Y|yes) ;; *) echo "Nothing removed."; exit 1 ;; esac
fi

case "$KIND" in
openwrt)
	remote "set -u
		if command -v apk >/dev/null; then PM=apk; else PM=opkg; fi
		d=\$(uci -q get gundil-update.main.data_dir || true) # Before the package goes.
		[ -x /etc/init.d/gundil-update-server ] && { /etc/init.d/gundil-update-server stop; /etc/init.d/gundil-update-server disable; } 2>/dev/null
		found=0
		for p in luci-app-gundil-update-server gundil-update-server; do
			if [ \$PM = apk ]; then
				apk info -e \$p >/dev/null 2>&1 && { apk del \$p; found=1; }
			else
				opkg status \$p 2>/dev/null | grep -q '^Status:.* installed' && { opkg remove \$p; found=1; }
			fi
		done
		[ \$found = 1 ] && echo 'Removed the packages.' || echo 'The update server was not installed.'
		rm -rf /var/etc/gundil-update-server.conf /www/gundil-update-server
		if [ $PURGE = 1 ]; then
			rm -rf /etc/gundil-update-server /etc/config/gundil-update /etc/config/gundil-update-opkg /etc/config/gundil-update.apk-new
			case \"\$d\" in /etc/gundil-update-server|'') ;; *) echo \"Kept the data folder you chose, \$d: delete it by hand if you like.\" ;; esac
			echo 'Deleted the data and settings.'
		else
			echo 'Kept the data (server key, devices, versions) in the data folder and the settings in /etc/config/gundil-update.'
		fi
		rm -f /tmp/luci-indexcache* 2>/dev/null; true"
	;;
linux)
	say "Removing (asks for the sudo password if needed)"
	ssh -t "$TARGET" "set -u
		sudo systemctl disable --now gundil-update-server 2>/dev/null || true
		if [ -e /etc/systemd/system/gundil-update-server.service ] || [ -d /opt/gundil-update-server ]; then
			echo 'Removed the service and the program.'
		else
			echo 'The update server was not installed.'
		fi
		sudo rm -f /etc/systemd/system/gundil-update-server.service /usr/local/bin/gundil-update-server \
			/usr/local/sbin/gundil-reset-portal
		sudo rm -rf /opt/gundil-update-server
		sudo systemctl daemon-reload
		if [ $PURGE = 1 ]; then
			sudo rm -rf /var/lib/gundil-update-server /etc/gundil-update-server.conf
			sudo userdel gundil-update 2>/dev/null || true
			echo 'Deleted the data and settings.'
		else
			echo 'Kept the data (server key, devices, versions) in /var/lib/gundil-update-server and the settings in /etc/gundil-update-server.conf.'
		fi"
	;;
windows)
	remote 'powershell -NoProfile -ExecutionPolicy Bypass -Command "
		$d=''C:\Program Files\Gundil Update Server''; $exe=Join-Path $d ''gundil-update-server.exe'';
		$g=Join-Path $env:ProgramData ''Gundil'';
		if (Get-Service GundilUpdateServer -ErrorAction SilentlyContinue) {
			if (Test-Path $exe) { & $exe uninstall } else { Stop-Service GundilUpdateServer -ErrorAction SilentlyContinue; sc.exe delete GundilUpdateServer | Out-Null };
			Write-Host ''Removed the GundilUpdateServer service.'' }
		else { Write-Host ''The GundilUpdateServer service was not installed.'' };
		Start-Sleep 1;
		Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue;
		if (Test-Path $d) { Write-Host (''Could not delete '' + $d + '' (in use?); delete it by hand.'') } else { Write-Host (''Deleted '' + $d) };
		if ('"$PURGE"' -eq 1) {
			Remove-Item -Recurse -Force (Join-Path $g ''update-server'') -ErrorAction SilentlyContinue;
			Remove-Item -Force (Join-Path $g ''update-server.conf'') -ErrorAction SilentlyContinue;
			if ((Test-Path $g) -and -not (Get-ChildItem $g -Force)) { Remove-Item $g };
			Write-Host ''Deleted the data and settings.'' }
		else { Write-Host (''Kept the data (server key, devices, versions) in '' + (Join-Path $g ''update-server'')) }"'
	;;
esac
say "Done."
