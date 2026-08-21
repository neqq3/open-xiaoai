#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/oh2p-airplay2-build}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist/oh2p-airplay2}"
BUNDLE="$OUT_DIR/open-xiaoai/addons/airplay2"

SHAIRPORT_REF="${SHAIRPORT_REF:-5.0.4}"
NQPTP_REF="${NQPTP_REF:-1.2.8}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
TARGET="arm-linux-gnueabihf"

export DEBIAN_FRONTEND=noninteractive

echo '[1/8] Installing amd64 build tools and armhf sysroot dependencies'
dpkg --add-architecture armhf
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git xz-utils file autoconf automake libtool make pkg-config \
  crossbuild-essential-armhf binutils-arm-linux-gnueabihf qemu-user-static \
  libpopt-dev:armhf libconfig-dev:armhf libasound2-dev:armhf \
  libavahi-client-dev:armhf libavahi-core-dev:armhf libssl-dev:armhf \
  libplist-dev:armhf libsodium-dev:armhf uuid-dev:armhf libgcrypt20-dev:armhf \
  libdaemon0:armhf libexpat1:armhf libdbus-1-3:armhf libcap2:armhf

rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$WORK_DIR" "$BUNDLE"/{bin,lib,etc,scripts,run}

FFPREFIX="$WORK_DIR/ffmpeg-prefix"

clone_with_retry() {
  local repo="$1" ref="$2" dest="$3" attempt
  for attempt in 1 2 3; do
    rm -rf "$dest"
    if git clone --depth 1 --branch "$ref" "$repo" "$dest"; then
      return 0
    fi
    echo "clone attempt $attempt failed for $repo@$ref" >&2
    if [[ "$attempt" -lt 3 ]]; then
      sleep 2
    fi
  done
  return 1
}

# Build a deliberately small FFmpeg runtime instead of pulling the full distro
# FFmpeg dependency graph. AirPlay 2 needs AAC/ALAC decoding plus resampling.
echo '[2/8] Cross-compiling minimal FFmpeg'
cd "$WORK_DIR"
clone_with_retry https://github.com/FFmpeg/FFmpeg.git "n${FFMPEG_VERSION}" "$WORK_DIR/ffmpeg"
cd "$WORK_DIR/ffmpeg"
./configure \
  --prefix="$FFPREFIX" \
  --target-os=linux \
  --arch=arm \
  --cpu=cortex-a7 \
  --cross-prefix=${TARGET}- \
  --enable-cross-compile \
  --enable-shared \
  --disable-static \
  --enable-small \
  --disable-programs \
  --disable-doc \
  --disable-debug \
  --disable-network \
  --disable-autodetect \
  --disable-everything \
  --enable-avutil \
  --enable-avcodec \
  --enable-avformat \
  --enable-swresample \
  --enable-decoder=aac \
  --enable-decoder=alac \
  --enable-parser=aac \
  --enable-protocol=file
make -j"$(nproc)"
make install

export PKG_CONFIG_LIBDIR="$FFPREFIX/lib/pkgconfig:/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig"
export PKG_CONFIG_PATH=""
export CPPFLAGS="-I$FFPREFIX/include"
export LDFLAGS="-L$FFPREFIX/lib"

echo '[3/8] Cross-compiling NQPTP'
cd "$WORK_DIR"
clone_with_retry https://github.com/mikebrady/nqptp.git "$NQPTP_REF" "$WORK_DIR/nqptp"
cd nqptp
autoreconf -fi
ac_cv_func_malloc_0_nonnull=yes \
ac_cv_func_realloc_0_nonnull=yes \
CC=${TARGET}-gcc ./configure --host="$TARGET" --build="$(gcc -dumpmachine)"
make -j"$(nproc)"
cp -L nqptp "$BUNDLE/bin/nqptp"

echo '[4/8] Cross-compiling Shairport Sync with AirPlay 2'
cd "$WORK_DIR"
clone_with_retry https://github.com/mikebrady/shairport-sync.git "$SHAIRPORT_REF" "$WORK_DIR/shairport-sync"
cd shairport-sync
autoreconf -fi
CC=${TARGET}-gcc ./configure \
  --host="$TARGET" \
  --build="$(gcc -dumpmachine)" \
  --with-alsa \
  --with-avahi \
  --with-ssl=openssl \
  --with-airplay-2
make -j"$(nproc)"
cp -L shairport-sync "$BUNDLE/bin/shairport-sync"

# Avahi is mandatory for upstream AirPlay 2. OH2P does not currently have it.
# Extract binaries without installing/running foreign-architecture maintainer scripts.
echo '[5/8] Extracting armhf Avahi and D-Bus runtime daemons'
cd "$WORK_DIR"
mkdir -p debs extracted
(
  cd debs
  apt-get download avahi-daemon:armhf dbus:armhf
)
for deb in debs/*.deb; do
  dpkg-deb -x "$deb" extracted
 done
cp -L extracted/usr/sbin/avahi-daemon "$BUNDLE/bin/avahi-daemon"
cp -L extracted/usr/bin/dbus-daemon "$BUNDLE/bin/dbus-daemon"

# Recursively copy ELF DT_NEEDED dependencies from the target sysroot and custom FFmpeg.
echo '[6/8] Collecting target runtime libraries'
READELF=${TARGET}-readelf
SEARCH_DIRS=(
  "$FFPREFIX/lib"
  /lib/arm-linux-gnueabihf
  /usr/lib/arm-linux-gnueabihf
)

find_lib() {
  local soname="$1" d
  for d in "${SEARCH_DIRS[@]}"; do
    if [[ -e "$d/$soname" ]]; then
      readlink -f "$d/$soname"
      return 0
    fi
  done
  return 1
}

queue=(
  "$BUNDLE/bin/shairport-sync"
  "$BUNDLE/bin/nqptp"
  "$BUNDLE/bin/avahi-daemon"
  "$BUNDLE/bin/dbus-daemon"
)
declare -A seen=()
while ((${#queue[@]})); do
  elf="${queue[0]}"
  queue=("${queue[@]:1}")
  while read -r soname; do
    [[ -n "$soname" ]] || continue
    [[ -n "${seen[$soname]:-}" ]] && continue
    seen[$soname]=1
    src="$(find_lib "$soname" || true)"
    if [[ -z "$src" ]]; then
      echo "ERROR: unresolved armhf runtime library: $soname (needed by $elf)" >&2
      exit 1
    fi
    cp -L "$src" "$BUNDLE/lib/$soname"
    queue+=("$BUNDLE/lib/$soname")
  done < <($READELF -d "$elf" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')
done

# Ship a matching glibc loader. Scripts invoke it explicitly, avoiding dependence
# on the old OH2P userspace loader/library set while still using the OH2P kernel.
LOADER="$(readlink -f /lib/ld-linux-armhf.so.3)"
cp -L "$LOADER" "$BUNDLE/lib/ld-linux-armhf.so.3"

cat > "$BUNDLE/etc/shairport-sync.conf" <<'EOF'
general = {
  name = "OH2P AirPlay 2 PoC";
  output_backend = "alsa";
};

alsa = {
  output_device = "hw:0,2";
};
EOF

cat > "$BUNDLE/etc/avahi-daemon.conf" <<'EOF'
[server]
use-ipv4=yes
use-ipv6=no
allow-interfaces=
disable-publishing=no
use-iff-running=no

[wide-area]
enable-wide-area=no

[publish]
publish-addresses=yes
publish-hinfo=no
publish-workstation=no
publish-domain=no

[reflector]
enable-reflector=no

[rlimits]
EOF

cat > "$BUNDLE/etc/dbus-poc.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=/tmp/oh2p-airplay2-dbus.sock</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF

cat > "$BUNDLE/scripts/env.sh" <<'EOF'
#!/bin/sh
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export AIRPLAY2_ROOT="$ROOT"
export LD_LIBRARY_PATH="$ROOT/lib"
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=/tmp/oh2p-airplay2-dbus.sock"
LOADER="$ROOT/lib/ld-linux-armhf.so.3"
run_armhf() {
  "$LOADER" --library-path "$ROOT/lib" "$@"
}
EOF

cat > "$BUNDLE/scripts/check-oh2p.sh" <<'EOF'
#!/bin/sh
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"
echo '=== OH2P AirPlay 2 PoC preflight ==='
uname -a
printf 'loader: '; test -e /lib/ld-linux-armhf.so.3 && echo OK || echo MISSING
printf '/data free: '; df -h /data 2>/dev/null | tail -n 1 || true
printf 'ALSA hw:0,2: '; aplay -D hw:0,2 --dump-hw-params /dev/zero 2>&1 | head -n 20 || true
echo '--- UDP 319/320/5353 listeners ---'
(netstat -ulnp 2>/dev/null || ss -ulnp 2>/dev/null || true) | grep -E ':(319|320|5353)[[:space:]]' || true
echo '--- processes relevant to audio/mDNS ---'
ps | grep -E 'mibrain|mediaplayer|mdnsd|avahi|nqptp|shairport' | grep -v grep || true
echo '--- bundled binary versions ---'
run_armhf "$ROOT/bin/nqptp" -V || true
run_armhf "$ROOT/bin/shairport-sync" -V || true
EOF

cat > "$BUNDLE/scripts/run-dbus.sh" <<'EOF'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"
rm -f /tmp/oh2p-airplay2-dbus.sock
exec "$LOADER" --library-path "$ROOT/lib" "$ROOT/bin/dbus-daemon" --nofork --config-file="$ROOT/etc/dbus-poc.conf"
EOF

cat > "$BUNDLE/scripts/run-avahi.sh" <<'EOF'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"
if (netstat -ulnp 2>/dev/null || ss -ulnp 2>/dev/null || true) | grep -q ':5353[[:space:]]'; then
  echo 'UDP 5353 is already in use (likely Xiaomi mdnsd). Refusing to kill or replace it automatically.' >&2
  echo 'For a temporary PoC, inspect the owner and stop mdnsd manually only if you accept the impact.' >&2
  exit 2
fi
exec "$LOADER" --library-path "$ROOT/lib" "$ROOT/bin/avahi-daemon" --no-drop-root --no-chroot -f "$ROOT/etc/avahi-daemon.conf"
EOF

cat > "$BUNDLE/scripts/run-nqptp.sh" <<'EOF'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"
exec "$LOADER" --library-path "$ROOT/lib" "$ROOT/bin/nqptp"
EOF

cat > "$BUNDLE/scripts/run-shairport-sync.sh" <<'EOF'
#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"
exec "$LOADER" --library-path "$ROOT/lib" "$ROOT/bin/shairport-sync" -c "$ROOT/etc/shairport-sync.conf" -v
EOF
chmod +x "$BUNDLE/scripts/"*.sh "$BUNDLE/bin/"*

# Strip only after dependency discovery.
${TARGET}-strip --strip-unneeded "$BUNDLE/bin/shairport-sync" "$BUNDLE/bin/nqptp" || true
for f in "$BUNDLE/lib/"*.so*; do
  ${TARGET}-strip --strip-unneeded "$f" 2>/dev/null || true
done

echo '[7/8] Verifying ELF architecture and executable startup under qemu-arm'
file "$BUNDLE/bin/"* "$BUNDLE/lib/ld-linux-armhf.so.3" | tee "$BUNDLE/ELF-INFO.txt"
qemu-arm-static "$BUNDLE/lib/ld-linux-armhf.so.3" --library-path "$BUNDLE/lib" "$BUNDLE/bin/nqptp" -V | tee "$BUNDLE/NQPTP-VERSION.txt"
qemu-arm-static "$BUNDLE/lib/ld-linux-armhf.so.3" --library-path "$BUNDLE/lib" "$BUNDLE/bin/shairport-sync" -V | tee "$BUNDLE/SHAIRPORT-VERSION.txt"

{
  echo "Shairport Sync ref: $SHAIRPORT_REF"
  echo "Shairport Sync commit: $(git -C "$WORK_DIR/shairport-sync" rev-parse HEAD)"
  echo "NQPTP ref: $NQPTP_REF"
  echo "NQPTP commit: $(git -C "$WORK_DIR/nqptp" rev-parse HEAD)"
  echo "FFmpeg: $FFMPEG_VERSION (minimal shared build: AAC + ALAC + swresample)"
  echo "FFmpeg commit: $(git -C "$WORK_DIR/ffmpeg" rev-parse HEAD)"
  echo "Target: $TARGET"
  echo "Build sysroot: Debian bullseye armhf"
  echo "Bundle install target: /data/open-xiaoai/addons/airplay2"
} > "$BUNDLE/BUILD-INFO.txt"

{
  echo '# DT_NEEDED closure shipped in bundle/lib'
  printf '%s\n' "${!seen[@]}" | sort
} > "$BUNDLE/DEPENDENCIES.txt"

{
  echo '# Bundle size'
  du -sh "$BUNDLE"
  echo
  echo '# Largest files'
  find "$BUNDLE" -type f -printf '%s %p\n' | sort -nr | head -n 40
} | tee "$BUNDLE/SIZE-REPORT.txt"

echo '[8/8] Creating deployable tarball'
cd "$OUT_DIR"
tar -czf oh2p-airplay2-armhf-poc.tar.gz open-xiaoai
sha256sum oh2p-airplay2-armhf-poc.tar.gz > oh2p-airplay2-armhf-poc.tar.gz.sha256
ls -lh oh2p-airplay2-armhf-poc.tar.gz
