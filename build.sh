#!/bin/bash
# Build QEMU with virgl GPU acceleration on macOS
# Tested on macOS 26.1 (Apple Silicon / arm64)
#
# Prerequisites (install with homebrew):
#   brew install meson ninja pkg-config glib pixman sdl2 libepoxy
#   brew install libslirp lzo snappy gnutls nettle libusb vde spice-protocol
#   brew install mesa molten-vk vulkan-headers vulkan-loader
#   brew install libssh jpeg-turbo
#   (binutils must NOT be first in PATH - macOS ar/ranlib needed)
#
# Usage: ./build.sh [--clean]

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$ROOT/install"
COMPAT="$ROOT/macos-compat/include"
MESA="/opt/homebrew/Cellar/mesa/26.0.0"

PKG_CONFIG_PATH="$INSTALL/lib/pkgconfig:$MESA/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"
export PKG_CONFIG_PATH

CFLAGS_EXTRA="-I$COMPAT -I$MESA/include"

if [ "$1" = "--clean" ]; then
    echo "==> Cleaning build directories..."
    rm -rf "$ROOT/libepoxy/build" "$ROOT/virglrenderer/build" "$ROOT/qemu/build" "$INSTALL"
fi

mkdir -p "$INSTALL"

# ── 1. libepoxy (with EGL patched for macOS) ─────────────────────────────────
echo ""
echo "==> Building libepoxy..."
mkdir -p "$ROOT/libepoxy/build"
cd "$ROOT/libepoxy"

PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
CFLAGS="$CFLAGS_EXTRA" \
meson setup build \
    --prefix="$INSTALL" \
    -Degl=yes -Dglx=no -Dx11=false -Dtests=false \
    2>&1 | tail -5

python3 -c "
import os, re
content = open('build/build.ninja').read()
fixed = content.replace('&& ranlib -c \$out', '&& /usr/bin/ranlib -c \$out')
open('build/build.ninja', 'w').write(fixed)
"
ninja -C build install

# ── 2. virglrenderer (EGL + Venus) ───────────────────────────────────────────
echo ""
echo "==> Building virglrenderer..."
mkdir -p "$ROOT/virglrenderer/build"
cd "$ROOT/virglrenderer"

PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
CFLAGS="$CFLAGS_EXTRA" \
AR=/usr/bin/ar \
meson setup build \
    --prefix="$INSTALL" \
    -Dplatforms=egl \
    -Dvenus=true \
    -Dvulkan-dload=true \
    -Drender-server-worker=thread \
    -Dtests=false \
    2>&1 | tail -5

python3 -c "
content = open('build/build.ninja').read()
fixed = content.replace('&& ranlib -c \$out', '&& /usr/bin/ranlib -c \$out')
open('build/build.ninja', 'w').write(fixed)
"
ninja -C build install

# ── 3. QEMU (with virgl + HVF + SDL) ─────────────────────────────────────────
echo ""
echo "==> Configuring QEMU..."
cd "$ROOT/qemu"

PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
PYTHON=/opt/homebrew/bin/python3.13 \
bash ./configure \
    --prefix="$INSTALL" \
    --target-list=x86_64-softmmu,aarch64-softmmu \
    --enable-virglrenderer \
    --enable-sdl \
    --enable-opengl \
    --enable-hvf \
    --disable-werror \
    --extra-cflags="-I$INSTALL/include -I$MESA/include" \
    --extra-ldflags="-L$INSTALL/lib -L$MESA/lib" \
    2>&1 | tail -20

echo ""
echo "==> Patching QEMU build.ninja for macOS ar/ranlib..."
python3 -c "
content = open('build/build.ninja').read()
# Use macOS ar (BSD format, no -D deterministic flag)
fixed = content.replace(' LINK_ARGS = csrD', ' LINK_ARGS = csr')
fixed = fixed.replace(' command = rm -f \$out && ar ', ' command = rm -f \$out && /usr/bin/ar ')
# Fix response file support (macOS ar doesn't support @rsp)
old_rsp = ' command = rm -f \$out && /usr/bin/ar \$LINK_ARGS \$out @\$out.rsp'
new_rsp = ' command = rm -f \$out && /Users/adrian.punga/work/qemu-virgl/macos-compat/ar-wrapper.sh \$LINK_ARGS \$out @\$out.rsp'
fixed = fixed.replace(old_rsp, new_rsp)
open('build/build.ninja', 'w').write(fixed)
print('Patched build.ninja')
"

echo ""
echo "==> Building QEMU..."
ninja -C build install

echo ""
echo "==> Done! QEMU installed to: $INSTALL/bin/"
ls "$INSTALL/bin/qemu-system-x86_64"
"$INSTALL/bin/qemu-system-x86_64" --version
