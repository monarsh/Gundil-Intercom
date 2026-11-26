#!/bin/sh
# Packs the update server as an AppImage for this machine's CPU (x86_64 or
# aarch64): one file that runs on any desktop Linux, e.g.
#   ./gundil-update-server-1.9.1-x86_64.AppImage          (runs the server)
#   ./gundil-update-server-1.9.1-x86_64.AppImage code     (prints the server code)
# Data: ~/.local/share/gundil-update-server.
# Usage: build_appimage.sh VERSION [RELEASE_KEY]
set -e
VERSION=${1:?version}
RELEASE_KEY=${2:-}
cd "$(dirname "$0")/../.."
case "$(uname -m)" in
x86_64) ARCH=x86_64 ;;
aarch64|arm64) ARCH=aarch64 ;;
*) echo "unsupported $(uname -m)"; exit 2 ;;
esac
APPDIR=build/appimage-server/GundilUpdateServer.AppDir
rm -rf "$APPDIR" && mkdir -p "$APPDIR/usr/bin"
CGO_ENABLED=0 go build -tags updateserver -trimpath -ldflags "-s -w -X main.version=$VERSION -X main.releaseKey=$RELEASE_KEY" \
	-o "$APPDIR/usr/bin/gundil-update-server" .
cp -r web "$APPDIR/usr/bin/web"
cat > "$APPDIR/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/gundil-update-server" "$@"
RUN
chmod +x "$APPDIR/AppRun"
cat > "$APPDIR/gundil-update-server.desktop" <<'D'
[Desktop Entry]
Type=Application
Name=Gundil Update Server
Exec=gundil-update-server
Icon=gundil-update-server
Terminal=true
Categories=Network;
D
cp ../linux/packaging/icons/gundil-intercom-256.png "$APPDIR/gundil-update-server.png"
ln -sf gundil-update-server.png "$APPDIR/.DirIcon"
TOOL="${APPIMAGETOOL:-build/appimagetool-$ARCH.AppImage}"
if [ ! -x "$TOOL" ]; then
	curl -fsSL -o "$TOOL" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
	chmod +x "$TOOL"
fi
mkdir -p dist-server
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" "$TOOL" --no-appstream "$APPDIR" \
	"dist-server/gundil-update-server-$VERSION-$ARCH.AppImage"
ls -la dist-server/*.AppImage
