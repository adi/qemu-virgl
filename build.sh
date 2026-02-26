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
echo "==> Patching SDL2 source for Mesa surfaceless EGL on macOS..."
cd "$ROOT/SDL"

# Patch SDL_cocoaopengles.m:
#   1. Use EGL_PLATFORM_SURFACELESS_MESA so Mesa's eglGetPlatformDisplayEXT is used
#      (eglGetDisplay(EGL_DEFAULT_DISPLAY) fails on macOS with Mesa → "Invalid window")
#   2. Set is_offscreen=true so SDL_EGL_ChooseConfig adds EGL_PBUFFER_BIT
#      (without it, eglCreatePbufferSurface fails on the chosen config)
#   3. Create a pbuffer surface instead of a CALayer window surface
#      (Mesa surfaceless EGL only supports pbuffer, not native window surfaces)
python3 -c "
import re, sys
mesa = sys.argv[1]
path = 'src/video/cocoa/SDL_cocoaopengles.m'
content = open(path).read()

# 1. Add EGL_PLATFORM_SURFACELESS_MESA define after the includes
define_block = '''/* Mesa surfaceless platform — eglGetDisplay(EGL_DEFAULT_DISPLAY) fails on macOS
 * with Mesa, but eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, ...) works.
 */
#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif'''
marker = '/* EGL implementation of SDL OpenGL support */'
if define_block not in content:
    content = content.replace(marker, marker + '\n\n' + define_block)

# 2. Change platform=0 to EGL_PLATFORM_SURFACELESS_MESA in both LoadLibrary calls
content = content.replace(
    'SDL_EGL_LoadLibrary(_this, NULL, EGL_DEFAULT_DISPLAY, 0)',
    'SDL_EGL_LoadLibrary(_this, NULL, EGL_DEFAULT_DISPLAY, EGL_PLATFORM_SURFACELESS_MESA)'
)

# 3. Remove unused NSView* v; declaration
content = re.sub(r'int Cocoa_GLES_SetupWindow\(_THIS, SDL_Window \* window\)\n\{\n    NSView\* v;\n',
                 'int Cocoa_GLES_SetupWindow(_THIS, SDL_Window * window)\n{\n', content)

# 4. Set is_offscreen=SDL_TRUE and use pbuffer instead of CALayer surface
old_surface = '''    /* Create the GLES window surface */
    v = windowdata.nswindow.contentView;
    windowdata.egl_surface = SDL_EGL_CreateSurface(_this, (__bridge NativeWindowType)[v layer]);'''
new_surface = '''    /* Signal that we use an offscreen (pbuffer) surface so SDL_EGL_ChooseConfig
     * adds EGL_SURFACE_TYPE = EGL_PBUFFER_BIT (required by Mesa surfaceless EGL). */
    _this->egl_data->is_offscreen = SDL_TRUE;

    /* Create the GLES window surface as a pbuffer (Mesa surfaceless EGL does not
     * support native window surfaces; use an offscreen pbuffer instead). */
    windowdata.egl_surface = SDL_EGL_CreateOffscreenSurface(_this, window->w, window->h);'''
if old_surface in content:
    content = content.replace(old_surface, new_surface)

open(path, 'w').write(content)
print('Patched SDL_cocoaopengles.m: surfaceless EGL + pbuffer surface')
" "$MESA"

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
echo "==> Patching QEMU source for macOS GL/EGL..."
cd "$ROOT/qemu"

# Fix 1: SDL_GL_SetAttribute for GLES must be called BEFORE SDL_CreateWindow.
# Fix 2: After creating the GL context, also create a Metal SDL renderer for
#         the readback display path (Mesa surfaceless EGL has no native window
#         surface, so we glReadPixels → SDL_Texture → Metal renderer instead of
#         SDL_GL_SwapWindow).
python3 -c "
path = 'ui/sdl2.c'
content = open(path).read()

# Patch 1: move SDL_GL_SetAttribute before SDL_CreateWindow
old1 = '''    if (scon->opengl) {
        flags |= SDL_WINDOW_OPENGL;
    }
#endif

    scon->real_window = SDL_CreateWindow'''
new1 = '''    if (scon->opengl) {
        flags |= SDL_WINDOW_OPENGL;
        /*
         * SDL_GL_SetAttribute MUST be called before SDL_CreateWindow because
         * EGL chooses the framebuffer config at window-creation time, not at
         * SDL_GL_CreateContext time.  Setting attributes after SDL_CreateWindow
         * is too late for EGL and causes SDL_GL_CreateContext to return NULL.
         */
        if (scon->opts->gl == DISPLAY_GL_MODE_ES) {
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                                SDL_GL_CONTEXT_PROFILE_ES);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
        }
    }
#endif

    scon->real_window = SDL_CreateWindow'''

# Patch 2: replace the old opengl branch that only creates winctx with one that
#          also creates a Metal renderer for the readback path.
old2 = '''    if (scon->opengl) {
        const char *driver = \"opengl\";

        if (scon->opts->gl == DISPLAY_GL_MODE_ES) {
            driver = \"opengles2\";
        }

        SDL_SetHint(SDL_HINT_RENDER_DRIVER, driver);
        SDL_SetHint(SDL_HINT_RENDER_BATCHING, \"1\");

        scon->winctx = SDL_GL_CreateContext(scon->real_window);
        SDL_GL_SetSwapInterval(0);
    } else {
        /* The SDL renderer is only used by sdl2-2D, when OpenGL is disabled */
        scon->real_renderer = SDL_CreateRenderer(scon->real_window, -1, 0);
    }'''
new2 = '''    if (scon->opengl) {
        scon->winctx = SDL_GL_CreateContext(scon->real_window);
        if (!scon->winctx) {
            fprintf(stderr, \"sdl2_window_create: SDL_GL_CreateContext failed: %s\\n\",
                    SDL_GetError());
        }
        SDL_GL_SetSwapInterval(0);
        /*
         * With Mesa surfaceless EGL, there is no native window surface to
         * present to.  Create a Metal-backed SDL renderer on the same window
         * so we can upload rendered frames via SDL_RenderCopy and present
         * them to the screen without using SDL_GL_SwapWindow.
         */
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, \"metal\");
        scon->real_renderer = SDL_CreateRenderer(scon->real_window, -1,
                                                 SDL_RENDERER_ACCELERATED);
        if (!scon->real_renderer) {
            fprintf(stderr, \"sdl2_window_create: SDL_CreateRenderer(metal) failed: %s\\n\",
                    SDL_GetError());
        }
    } else {
        /* The SDL renderer is only used by sdl2-2D, when OpenGL is disabled */
        scon->real_renderer = SDL_CreateRenderer(scon->real_window, -1, 0);
    }'''

applied = []
if old1 in content:
    content = content.replace(old1, new1)
    applied.append('SetAttribute-before-CreateWindow')
if old2 in content:
    content = content.replace(old2, new2)
    applied.append('metal-renderer')
if applied:
    open(path, 'w').write(content)
    print('Patched ui/sdl2.c:', ', '.join(applied))
elif 'SDL_HINT_RENDER_DRIVER, \"metal\"' in content:
    print('ui/sdl2.c already patched')
else:
    print('WARNING: could not patch ui/sdl2.c - patterns not found', flush=True)
"

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
