#!/usr/bin/env bash
# Build a .deb from a Flutter Linux release bundle.
#   installer/linux/build-deb.sh <bundle-dir> <version> <out-dir> [arch]
set -euo pipefail
bundle="$1"; version="$2"; out="$3"; arch="${4:-amd64}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
pkg=$(mktemp -d)
install -d "$pkg/DEBIAN" "$pkg/opt/linkory-app" "$pkg/usr/share/applications" "$pkg/usr/bin"
cp -r "$bundle"/. "$pkg/opt/linkory-app/"
for n in 32 64 128 256 512; do
  install -D -m 644 "$root/linkory-app/assets/icons/app_$n.png" "$pkg/usr/share/icons/hicolor/${n}x${n}/apps/com.yuhuo.linkory.png"
done
cat > "$pkg/usr/share/applications/com.yuhuo.linkory.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=连信 Linkory
Name[en]=Linkory
Comment=在你的设备之间互发消息和文件
Exec=/opt/linkory-app/linkory_app
Icon=com.yuhuo.linkory
Terminal=false
Categories=Network;Chat;
StartupWMClass=com.yuhuo.linkory
DESKTOP
chmod 644 "$pkg/usr/share/applications/com.yuhuo.linkory.desktop"
ln -s /opt/linkory-app/linkory_app "$pkg/usr/bin/linkory"
cat > "$pkg/DEBIAN/control" <<CONTROL
Package: linkory
Version: ${version}
Section: net
Priority: optional
Architecture: ${arch}
Maintainer: yuhuotech
Depends: libgtk-3-0, libsecret-1-0, libayatana-appindicator3-1, libnotify4
Description: Linkory - send messages and files between your own devices
 Self-hosted device-to-device messaging and file transfer.
CONTROL
cat > "$pkg/DEBIAN/postinst" <<'POST'
#!/bin/sh
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true
exit 0
POST
chmod 755 "$pkg/DEBIAN/postinst"
mkdir -p "$out"
dpkg-deb --build --root-owner-group "$pkg" "$out/Linkory-${version}-linux-${arch}.deb"
rm -rf "$pkg"
