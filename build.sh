#!/bin/bash
# Build QEMU with virgl GPU acceleration on macOS
# Tested on macOS 26.1 (Apple Silicon / arm64)
#
# Prerequisites (install with homebrew):
#   brew install meson ninja pkg-config cmake glib pixman
#   brew install libslirp lzo snappy gnutls nettle libusb vde spice-protocol
#   brew install mesa molten-vk vulkan-headers vulkan-loader
#   brew install libssh jpeg-turbo
#   (binutils must NOT be first in PATH - macOS ar/ranlib needed)
#   (do NOT install homebrew sdl2 - we build SDL2 from source for EGL support)
#
# Sources to clone before running:
#   git clone https://github.com/anholt/libepoxy.git
#   git clone https://gitlab.freedesktop.org/virgl/virglrenderer.git
#   git clone https://gitlab.com/qemu-project/qemu.git --depth=1
#   git clone https://github.com/libsdl-org/SDL.git --branch SDL2 SDL
#
# Usage: ./build.sh [--clean]

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$ROOT/install"
COMPAT="$ROOT/macos-compat/include"
MESA="/opt/homebrew/Cellar/mesa/26.0.0"

export PKG_CONFIG_PATH="$INSTALL/lib/pkgconfig:$MESA/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"

CFLAGS_EXTRA="-I$COMPAT -I$MESA/include"

if [ "$1" = "--clean" ]; then
    echo "==> Cleaning build directories..."
    rm -rf "$ROOT/libepoxy/build" "$ROOT/virglrenderer/build" "$ROOT/SDL/build" "$ROOT/qemu/build" "$INSTALL"
fi

mkdir -p "$INSTALL"

apply_patch_if_needed() {
    local repo="$1"
    local patch="$2"

    if [ ! -f "$patch" ]; then
        echo "[ERR] Patch file not found: $patch"
        return 1
    fi

    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        echo "==> Patch already applied: $(basename "$patch")"
        return 0
    fi

    if git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        git -C "$repo" apply "$patch"
        echo "==> Applied patch: $(basename "$patch")"
        return 0
    fi

    echo "[ERR] Failed to apply patch: $patch"
    git -C "$repo" apply --check "$patch"
    return 1
}

apply_patch_dir() {
    local repo="$1"
    local patch_dir="$2"
    local patch

    if [ ! -d "$patch_dir" ]; then
        echo "[ERR] Missing patch directory: $patch_dir"
        return 1
    fi

    for patch in "$patch_dir"/*.patch; do
        [ -f "$patch" ] || continue
        apply_patch_if_needed "$repo" "$patch"
    done
}

# ── 1. libepoxy (with EGL patched for macOS) ─────────────────────────────────
echo ""
echo "==> Building libepoxy..."
cd "$ROOT/libepoxy"

# Patch libepoxy to use Mesa's GL/EGL/GLES libs instead of Apple's OpenGL.framework.
# Apple's libGL crashes (NULL dereference in glGetString) without a CGL context active.
python3 -c "
import sys
mesa = sys.argv[1]
path = 'src/dispatch_common.c'
content = open(path).read()
# Replace the Apple #if block's lib defines to point to Mesa
old = '''#if defined(__APPLE__)
#define GLX_LIB \"/opt/X11/lib/libGL.1.dylib\"
#define OPENGL_LIB \"/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL\"
#define EGL_LIB \"libEGL.dylib\"
#define GLES1_LIB \"libGLESv1_CM.dylib\"
#define GLES2_LIB \"libGLESv2.dylib\"'''
new = '''#if defined(__APPLE__)
#define GLX_LIB \"/opt/X11/lib/libGL.1.dylib\"
/* Use Mesa libs instead of Apple OpenGL.framework (crashes on macOS 26.1 without CGL context) */
#define OPENGL_LIB \"''' + mesa + '''/lib/libGL.dylib\"
#define EGL_LIB \"''' + mesa + '''/lib/libEGL.dylib\"
#define GLES1_LIB \"''' + mesa + '''/lib/libGLESv1_CM.dylib\"
#define GLES2_LIB \"''' + mesa + '''/lib/libGLESv2.dylib\"'''
if old in content:
    content = content.replace(old, new)
    open(path, 'w').write(content)
    print('Patched libepoxy dispatch_common.c: OPENGL_LIB -> Mesa')
else:
    # Already patched or different version - just ensure OPENGL_LIB is not Apple
    if 'OpenGL.framework' in content:
        content = content.replace(
            '/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL',
            mesa + '/lib/libGL.dylib'
        )
        open(path, 'w').write(content)
        print('Patched OPENGL_LIB in dispatch_common.c')
    else:
        print('libepoxy already patched')
" "$MESA"

CFLAGS="$CFLAGS_EXTRA" \
meson setup build \
    --prefix="$INSTALL" \
    -Degl=yes -Dglx=no -Dx11=false -Dtests=false \
    2>&1 | tail -5

# Fix epoxy_conservative_egl_version to return 14 (conservative minimum) when
# eglQueryString(EGL_VERSION) returns NULL (EGL_NOT_INITIALIZED).  Mesa on
# macOS surfaceless EGL can return a non-NULL display handle that is in a
# partially-initialised state during early GL dispatch, causing the version
# query to fail and libepoxy to abort with "No provider of eglGetCurrentContext".
python3 -c "
path = 'src/dispatch_egl.c'
content = open(path).read()
old = '    return epoxy_egl_version(dpy);\n}'
new = '''    int v = epoxy_egl_version(dpy);

    /* Mesa on macOS (surfaceless EGL) may return a display handle for which
     * eglQueryString(EGL_VERSION) fails with EGL_NOT_INITIALIZED during early
     * GL dispatch.  Return the conservative minimum so basic EGL 1.4 functions
     * can still be dispatched. */
    if (v == 0)
        return 14;

    return v;
}'''
if old in content:
    content = content.replace(old, new)
    open(path, 'w').write(content)
    print('Patched libepoxy dispatch_egl.c: conservative EGL version fallback')
elif 'if (v == 0)' in content:
    print('dispatch_egl.c already patched')
else:
    print('WARNING: could not patch dispatch_egl.c', flush=True)
"

python3 -c "
content = open('build/build.ninja').read()
fixed = content.replace('&& ranlib -c \$out', '&& /usr/bin/ranlib -c \$out')
open('build/build.ninja', 'w').write(fixed)
"
ninja -C build install

# ── 2. virglrenderer (EGL + Venus) ───────────────────────────────────────────
echo ""
echo "==> Building virglrenderer..."
cd "$ROOT/virglrenderer"

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

# ── 3. SDL2 from source (EGL backend, avoids broken Apple OpenGL.framework) ──
# macOS 26.1 has a broken Apple OpenGL.framework (CGLChoosePixelFormat crashes).
# Build SDL2 with SDL_OPENGLES=ON to use Mesa EGL instead of Apple CGL.
echo ""
echo "==> Applying SDL2 patch series..."
cd "$ROOT/SDL"
apply_patch_dir "$ROOT/SDL" "$ROOT/patches/sdl2"

echo "==> Building SDL2 (EGL/GLES2 backend)..."

cmake -S . -B build \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSDL_OPENGLES=ON \
    -DSDL_OPENGL=OFF \
    -DOPENGL_INCLUDE_DIR="$MESA/include" \
    -DOPENGL_gl_LIBRARY="$MESA/lib/libGL.dylib" \
    -DOPENGLES2_INCLUDE_DIR="$MESA/include" \
    -DOPENGLES2_LIBRARY="$MESA/lib/libGLESv2.dylib" \
    -DEGL_INCLUDE_DIR="$MESA/include" \
    -DEGL_LIBRARY="$MESA/lib/libEGL.dylib" \
    2>&1 | tail -5

cmake --build build --parallel "$(sysctl -n hw.ncpu)"
cmake --install build

# ── 4. QEMU (with virgl + HVF + SDL) ─────────────────────────────────────────
echo ""
echo "==> Applying QEMU patch series..."
cd "$ROOT/qemu"
apply_patch_dir "$ROOT/qemu" "$ROOT/patches/qemu-upstream"

echo ""
echo "==> Configuring QEMU..."

PYTHON=/opt/homebrew/bin/python3.13 \
bash ./configure \
    --prefix="$INSTALL" \
    --target-list=x86_64-softmmu,aarch64-softmmu \
    --enable-virglrenderer \
    --enable-sdl \
    --enable-opengl \
    --enable-hvf \
    --disable-werror \
    "--extra-cflags=-I$INSTALL/include -I$MESA/include -I/opt/homebrew/include" \
    "--extra-ldflags=-L$INSTALL/lib -L$MESA/lib -L/opt/homebrew/lib" \
    2>&1 | tail -20

echo ""
echo "==> Patching QEMU build.ninja for macOS ar/ranlib/linker..."
AR_WRAPPER="$ROOT/macos-compat/ar-wrapper.sh"
python3 - "$INSTALL" "$MESA" "$AR_WRAPPER" << 'PYEOF'
import sys
install, mesa, ar_wrapper = sys.argv[1], sys.argv[2], sys.argv[3]
content = open('build/build.ninja').read()

# Use macOS ar (BSD format, no -D deterministic flag)
fixed = content.replace(' LINK_ARGS = csrD', ' LINK_ARGS = csr')
fixed = fixed.replace(' command = rm -f $out && ar ', ' command = rm -f $out && /usr/bin/ar ')
# Fix response file support (macOS ar doesn't support @rsp)
old_rsp = ' command = rm -f $out && /usr/bin/ar $LINK_ARGS $out @$out.rsp'
new_rsp = f' command = rm -f $out && {ar_wrapper} $LINK_ARGS $out @$out.rsp'
fixed = fixed.replace(old_rsp, new_rsp)
# Fix ranlib (use macOS BSD ranlib)
fixed = fixed.replace('&& ranlib -c $out', '&& /usr/bin/ranlib -c $out')
# Move LINK_ARGS before $in in objc_LINKER rule so -L paths precede -l references
fixed = fixed.replace(
    ' command = clang $ARGS -o $out $in $LINK_ARGS',
    ' command = clang $ARGS $LINK_ARGS -o $out $in'
)
# Add -L paths to per-target LINK_ARGS of qemu-system executables
# so bare -lsnappy, -lfdt etc. can be resolved (pkg-config doesn't provide full paths for all)
EXTRA_L = f'-L{install}/lib -L{mesa}/lib -L/opt/homebrew/lib'
for target in ['qemu-system-x86_64-unsigned', 'qemu-system-aarch64-unsigned']:
    idx = fixed.find(f'build {target}:')
    if idx < 0:
        continue
    block_end = fixed.find('\n\n', idx)
    if block_end < 0:
        block_end = idx + 50000
    block = fixed[idx:block_end]
    la_marker = ' LINK_ARGS = '
    la_idx = block.rfind(la_marker)
    if la_idx >= 0 and EXTRA_L not in block[la_idx:la_idx+200]:
        new_block = block[:la_idx] + la_marker + EXTRA_L + ' ' + block[la_idx+len(la_marker):]
        fixed = fixed[:idx] + new_block + fixed[idx+len(block):]
        print(f'Added -L paths for {target}')

open('build/build.ninja', 'w').write(fixed)
print('Patched build.ninja')
PYEOF

echo ""
echo "==> Building QEMU..."
ninja -C build install

# Fix rpaths in QEMU binaries:
#   - install/lib  : finds libSDL2-2.0.0.dylib, libepoxy.0.dylib, libvirglrenderer.so, etc.
#   - Mesa/lib     : finds libEGL.dylib, libGLESv2.dylib (needed by SDL's EGL loader)
#   - /opt/homebrew/lib : finds libsnappy, libgnutls, etc.
# These rpaths are embedded in the binary so the binary works without DYLD_LIBRARY_PATH.
echo ""
echo "==> Fixing rpath in installed QEMU binaries..."
for bin in "$INSTALL/bin/qemu-system-x86_64" "$INSTALL/bin/qemu-system-aarch64"; do
    [ -f "$bin" ] || continue
    for rpath in "$INSTALL/lib" "$MESA/lib" "/opt/homebrew/lib"; do
        install_name_tool -add_rpath "$rpath" "$bin" 2>/dev/null || true
    done
    echo "  Fixed rpaths in $bin"
done

echo ""
echo "==> Done! QEMU installed to: $INSTALL/bin/"
ls "$INSTALL/bin/qemu-system-x86_64"
DYLD_LIBRARY_PATH="$INSTALL/lib:$MESA/lib" "$INSTALL/bin/qemu-system-x86_64" --version
