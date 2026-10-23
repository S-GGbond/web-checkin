#!/usr/bin/env bash
# 把 flutter build linux --release 的产物打成 deb / rpm 安装包。
#
#   tools/package/package.sh deb     # 只打 deb
#   tools/package/package.sh rpm     # 只打 rpm（用 docker + rockylinux 跑 rpmbuild）
#   tools/package/package.sh         # 两个都打
#
# 安装布局：
#   /opt/checkin_hub/{checkin_hub,data,lib}   完整 bundle（二进制必须与 data、lib 同级）
#   /usr/bin/checkin_hub                      指向 bundle 内二进制的软链接
#   /usr/share/applications/checkin_hub.desktop
#   /usr/share/icons/hicolor/1024x1024/apps/checkin_hub.png
set -euo pipefail

PKG=checkin-hub
APP=checkin_hub
VERSION=1.0.0
RELEASE=1
DEB_ARCH=amd64
RPM_ARCH=x86_64
MAINTAINER="checkin hub <noreply@localhost>"
SUMMARY="WorkBuddy / Trae 多账号签到中枢"
DESCRIPTION="多账号签到与额度查询的桌面客户端：本地账号库、后台定时签到、多平台登录态管理。"
HOMEPAGE="https://github.com/"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BUNDLE="$ROOT/build/linux/x64/release/bundle"
OUT="$ROOT/dist"
WORK="$ROOT/build/package"
STAGE="$WORK/root"
TARGETS="$*"
if [ -z "$TARGETS" ]; then TARGETS="deb rpm"; fi

command -v dpkg-deb >/dev/null || { echo "缺少 dpkg-deb" >&2; exit 1; }

if [ ! -x "$BUNDLE/$APP" ]; then
  echo "==> 先构建 release bundle"
  ( cd "$ROOT" && flutter build linux --release )
fi

echo "==> 准备安装树 $STAGE"
rm -rf "$STAGE"
install -d "$STAGE/opt/$APP" \
           "$STAGE/usr/bin" \
           "$STAGE/usr/share/applications" \
           "$STAGE/usr/share/icons/hicolor/1024x1024/apps" \
           "$STAGE/usr/share/doc/$PKG"
cp -a "$BUNDLE/." "$STAGE/opt/$APP/"
ln -sfn "/opt/$APP/$APP" "$STAGE/usr/bin/$APP"
install -m 0644 "$BUNDLE/data/app_icon.png" "$STAGE/usr/share/icons/hicolor/1024x1024/apps/$APP.png"
install -m 0644 "$ROOT/README.md" "$STAGE/usr/share/doc/$PKG/README.md"

cat > "$STAGE/usr/share/applications/$APP.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=签到中枢
GenericName=Check-in Hub
Comment=$SUMMARY
Exec=/usr/bin/$APP
Icon=$APP
Terminal=false
Categories=Utility;Office;
Keywords=checkin;签到;workbuddy;trae;
StartupWMClass=dev.checkinhub.checkin_hub
StartupNotify=true
EOF

mkdir -p "$OUT"

build_deb() {
  echo "==> 打 deb"
  local root="$WORK/deb"
  rm -rf "$root"
  cp -a "$STAGE" "$root"
  install -d "$root/DEBIAN"
  local size
  size=$(du -sk --exclude=DEBIAN "$root" | cut -f1)
  cat > "$root/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION-$RELEASE
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $size
Depends: libc6, libstdc++6, libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libblkid1, liblzma5, libxkbcommon0, libepoxy0
Recommends: xdg-utils
Maintainer: $MAINTAINER
Homepage: $HOMEPAGE
Description: $SUMMARY
 $DESCRIPTION
EOF
  cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
  command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
EOF
  cat > "$root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
  command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
EOF
  chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"
  # 产物统一命名：checkin-hub_<版本>_<架构>
  dpkg-deb --root-owner-group -Zxz --build "$root" "$OUT/$PKG"_"$VERSION"_"$DEB_ARCH.deb" >/dev/null
}

build_rpm() {
  echo "==> 打 rpm"
  command -v docker >/dev/null || { echo "缺少 docker，无法生成 rpm" >&2; return 1; }
  local ctx="$WORK/rpm"
  rm -rf "$ctx"
  local stage="$ctx/stage"
  install -d "$stage"
  cp -a "$STAGE/." "$stage/"
  tar -C "$stage" -czf "$ctx/$PKG-$VERSION.tar.gz" .
  cat > "$ctx/$PKG.spec" <<EOF
Name:           $PKG
Version:        $VERSION
Release:        $RELEASE
Summary:        $SUMMARY
License:        Proprietary
URL:            $HOMEPAGE
BuildArch:      $RPM_ARCH
Requires:       gtk3
Requires:       glib2
Requires:       libstdc++
Requires:       libblkid
Requires:       xz-libs

%description
$DESCRIPTION

%prep

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a %{_sourcedir}/stage/. %{buildroot}/

%files
/opt/checkin_hub
/usr/bin/checkin_hub
/usr/share/applications/checkin_hub.desktop
/usr/share/icons/hicolor/1024x1024/apps/checkin_hub.png
/usr/share/doc/checkin-hub

%changelog
EOF
  docker run --rm \
    -v "$ctx:/pkg:ro" \
    -v "$OUT:/out" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    rockylinux:9 \
    bash -c 'dnf -y install rpm-build >/dev/null 2>&1 && rpmbuild --define "_topdir /tmp/rpmbuild" --define "_sourcedir /pkg" --define "_binary_payload w2.xzdio" -bb /pkg/checkin-hub.spec >/dev/null && cp /tmp/rpmbuild/RPMS/*/*.rpm /out/ && chown "$HOST_UID:$HOST_GID" /out/*.rpm && ls /out/*.rpm'
  # rpmbuild 产出 name-version-release.arch.rpm，统一改成发布资产命名
  local produced
  produced=$(ls -t "$OUT"/"$PKG"-*.rpm 2>/dev/null | head -1 || true)
  if [ -n "$produced" ]; then
    mv -f "$produced" "$OUT/$PKG"_"$VERSION"_"$RPM_ARCH.rpm"
  fi
}

case " $TARGETS " in *" deb "*) build_deb ;; esac
case " $TARGETS " in *" rpm "*) build_rpm ;; esac

echo "==> 产物"
ls -lh "$OUT" | awk 'NR>1 {print "   " $9 "  " $5}'
