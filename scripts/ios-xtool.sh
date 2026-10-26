#!/usr/bin/env bash
# Build, sign and install the TrailMind iPhone preview from Linux or WSL with xtool and
# omarchy-apple-dev (https://github.com/joshuaswarren/omarchy-apple-dev). No Mac or Xcode install.
#
#   scripts/ios-xtool.sh setup            Swift 6.4 + libimobiledevice + omarchy-apple-dev toolchain (Ubuntu)
#   XCODE_XIP=/path/Xcode_27.x.xip scripts/ios-xtool.sh setup   ...then register the iOS SDK
#   scripts/ios-xtool.sh test             LocationText unit tests on Linux (no iOS SDK needed)
#   scripts/ios-xtool.sh auth             once: sign xtool in to your Apple ID (interactive)
#   scripts/ios-xtool.sh devices          list connected iPhones and their UDIDs
#   scripts/ios-xtool.sh build            xtool dev build -> ~/trailmind-ios/xtool/TrailMind.app under WSL
#   scripts/ios-xtool.sh run [--udid ID]  sign with your Apple ID, install and launch on a USB iPhone
#   scripts/ios-xtool.sh pair-network     one-time USB pairing record for cable-free installs (iOS 27)
#   scripts/ios-xtool.sh run-network IP   install + launch over Wi-Fi/Tailscale (iOS 27, after pair-network)
#
# Apple ID sign-in happens once with `xtool auth`. Credentials, pairing records and signing keys stay in
# $HOME on this machine; never copy them into the repository.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/ios"
OAD_DIR="${OAD_DIR:-$HOME/omarchy-apple-dev}"
OAD_URL="https://github.com/joshuaswarren/omarchy-apple-dev"
SWIFT_VERSION="${SWIFT_VERSION:-6.4.1}"
SWIFT_ROOT="$HOME/.local/swift-$SWIFT_VERSION"
IMD_PREFIX="$HOME/.local/imobiledevice"

export PATH="$SWIFT_ROOT/usr/bin:$HOME/.local/bin:$IMD_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$IMD_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$IMD_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Under WSL, use Apple's Windows usbmuxd (Apple Devices app, 127.0.0.1:27015 with mirrored networking):
# usbipd-win forwarding stalls installs (iPhone rejects 65536-byte bursts; dorssel/usbipd-win#867).
# Otherwise use the Linux socket; pymobiledevice3 would wrongly look for the Windows port inside WSL.
if [[ -z "${USBMUXD_SOCKET_ADDRESS:-}" ]]; then
  if grep -qi microsoft /proc/version 2>/dev/null && timeout 2 bash -c '</dev/tcp/127.0.0.1/27015' 2>/dev/null; then
    export USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015
  elif [[ -S /var/run/usbmuxd ]]; then
    export USBMUXD_SOCKET_ADDRESS=/var/run/usbmuxd
  fi
fi

die() { echo "error: $*" >&2; exit 1; }
need_linux() { [[ "$(uname -s)" == Linux ]] || die "run this inside Linux or WSL (see docs/iphone-development.md)"; }

# A project on /mnt/c is very slow for SwiftPM and loses Unix permissions, so build from a Linux-side copy.
sync_ios() {
  local dest="$HOME/trailmind-ios"
  if [[ "$IOS_DIR" == /mnt/* ]]; then
    mkdir -p "$dest"
    rsync -a --delete --exclude .build --exclude xtool --exclude .bsp --exclude Generated \
      --exclude TrailMind.xcodeproj "$IOS_DIR/" "$dest/"
    echo "$dest"
  else
    echo "$IOS_DIR"
  fi
}

install_swift() {
  [[ -x "$SWIFT_ROOT/usr/bin/swift" ]] && return
  . /etc/os-release
  local plat="ubuntu${VERSION_ID}" arch=""
  [[ "$(uname -m)" == aarch64 ]] && arch="-aarch64"
  local name="swift-$SWIFT_VERSION-RELEASE-${plat}${arch}"
  local url="https://download.swift.org/swift-$SWIFT_VERSION-release/${plat//./}${arch}/swift-$SWIFT_VERSION-RELEASE/$name.tar.gz"
  echo "==> Swift $SWIFT_VERSION from $url"
  mkdir -p "$SWIFT_ROOT"
  # Keep the usr/ level: SwiftPM finds the toolchain by walking up to usr/lib/swift.
  curl -fL "$url" | tar -xz --strip-components=1 -C "$SWIFT_ROOT"
}

install_imobiledevice() {
  if ! { pkg-config --exists libimobiledevice-1.0 2>/dev/null \
      && pkg-config --atleast-version=1.3.1 libimobiledevice-1.0; }; then
    # Ubuntu 24.04's libimobiledevice 1.3.0 lacks idevice_events_subscribe, which xtool needs.
    echo "==> libimobiledevice stack from source into $IMD_PREFIX"
    local src="$HOME/.cache/imobiledevice-src"
    mkdir -p "$src"
    for r in libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice; do
      [[ -d "$src/$r" ]] || git clone --depth 1 "https://github.com/libimobiledevice/$r" "$src/$r"
      (cd "$src/$r" && ./autogen.sh --prefix="$IMD_PREFIX" >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null)
    done
  fi
  # xtool links against these libraries, so make them visible outside this script as well.
  [[ -d "$IMD_PREFIX/lib" ]] && echo "$IMD_PREFIX/lib" | sudo tee /etc/ld.so.conf.d/trailmind-imobiledevice.conf >/dev/null \
    && sudo ldconfig
  return 0
}

cmd_setup() {
  need_linux
  echo "==> Ubuntu packages (sudo)"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    autoconf automake binutils build-essential ca-certificates cmake curl file git gnupg2 libtool \
    libc6-dev libcurl4-openssl-dev libedit2 libfuse3-dev libbz2-dev libheif-dev libheif-examples \
    liblzma-dev libncurses-dev libpython3-dev libssl-dev libstdc++-14-dev libxml2-dev libz3-dev llvm \
    pkg-config poppler-utils python3 python3-venv rsync unzip usbmuxd zip zlib1g-dev
  install_swift
  install_imobiledevice
  swift --version
  if [[ -d "$OAD_DIR/.git" ]]; then git -C "$OAD_DIR" pull --ff-only; else git clone "$OAD_URL" "$OAD_DIR"; fi
  echo "==> omarchy-apple-dev install-toolchain.sh --mode full ${XCODE_XIP:+(XCODE_XIP=$XCODE_XIP)}"
  local rc=0
  (cd "$OAD_DIR" && ./install-toolchain.sh --mode full) || rc=$?
  pmd3_python313
  if (( rc )); then
    swift sdk list 2>/dev/null | grep -q darwin && exit "$rc"
    echo "Toolchain ready except the iOS SDK. Download Xcode 27 and re-run: XCODE_XIP=/path/Xcode_27.x.xip $0 setup" >&2
    exit 3
  fi
}

# Cable-free installs tunnel with TLS-PSK and QUIC, which need Python 3.13+ (omarchy docs/OVER-TAILNET.md).
# device-run.sh uses ~/pymobile3-venv for that, so rebuild it on 3.13 when the system Python is older.
pmd3_python313() {
  local venv="$HOME/pymobile3-venv"
  if [[ -x "$venv/bin/python" ]] && "$venv/bin/python" -c 'import sys; sys.exit(sys.version_info < (3, 13))'; then
    return
  fi
  if ! command -v python3.13 >/dev/null; then
    echo "==> Python 3.13 from ppa:deadsnakes/ppa (sudo)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3.13 python3.13-venv python3.13-dev
  fi
  echo "==> pymobiledevice3 venv on Python 3.13"
  rm -rf "$venv"
  python3.13 -m venv "$venv"
  "$venv/bin/pip" install -q --upgrade pip pymobiledevice3
  "$venv/bin/pymobiledevice3" version
}

cmd_test() {
  need_linux
  command -v swift >/dev/null || die "swift not found; run setup first"
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/Sources/TrailMind" "$tmp/Tests/TrailMindTests"
  cp "$IOS_DIR/TrailMind/LocationText.swift" "$IOS_DIR/TrailMind/MapLayer.swift" "$tmp/Sources/TrailMind/"
  cp "$IOS_DIR/TrailMindTests/LocationTextTests.swift" "$IOS_DIR/TrailMindTests/MapLayerTests.swift" "$tmp/Tests/TrailMindTests/"
  cat > "$tmp/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TrailMind",
  targets: [.target(name: "TrailMind"), .testTarget(name: "TrailMindTests", dependencies: ["TrailMind"])],
  swiftLanguageModes: [.v5])
EOF
  (cd "$tmp" && swift test)
}

xtool_env() {
  command -v xtool >/dev/null || die "xtool not found; run setup first"
  swift sdk list 2>/dev/null | grep -q darwin \
    || die "the darwin iOS SDK is not registered; run: XCODE_XIP=/path/Xcode_27.x.xip $0 setup"
  # The Swift toolchain's clang must win over the system clang (omarchy-apple-dev README, Notes).
  PATH="$(dirname "$(readlink -f "$(command -v swift)")"):$PATH"
  ulimit -n 65536 2>/dev/null || true
}

cmd_auth() {
  need_linux
  command -v xtool >/dev/null || die "xtool not found; run setup first"
  xtool auth "$@"
}

cmd_devices() {
  need_linux
  command -v xtool >/dev/null || die "xtool not found; run setup first"
  xtool devices
}

cmd_build() {
  need_linux; xtool_env
  local dir; dir="$(sync_ios)"
  (cd "$dir" && xtool dev build)
  echo "Built $dir/xtool/TrailMind.app"
}

cmd_run() {
  need_linux; xtool_env
  local dir; dir="$(sync_ios)"
  (cd "$dir" && "$OAD_DIR/device-run.sh" "$@")
}

cmd_pair_network() {
  need_linux
  pmd3_python313
  "$HOME/pymobile3-venv/bin/python" "$OAD_DIR/tools/tailnet-tunnel.py" pair
}

cmd_run_network() {
  need_linux; xtool_env
  local ip="${1:-}"; [[ -n "$ip" ]] || die "usage: $0 run-network PHONE_IP"
  local dir; dir="$(sync_ios)"
  # Signed with the `xtool auth` Apple ID. A free account's profile only covers devices it has seen,
  # so run `run` over USB once before the first cable-free install.
  (cd "$dir" && xtool dev build --sign --ipa)
  "$OAD_DIR/device-run.sh" --over-tailnet "$ip" "$dir/xtool/TrailMind.ipa"
}

case "${1:-}" in
  setup) shift; cmd_setup "$@" ;;
  test) shift; cmd_test "$@" ;;
  auth) shift; cmd_auth "$@" ;;
  devices) shift; cmd_devices "$@" ;;
  build) shift; cmd_build "$@" ;;
  run) shift; cmd_run "$@" ;;
  pair-network) shift; cmd_pair_network "$@" ;;
  run-network) shift; cmd_run_network "$@" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
