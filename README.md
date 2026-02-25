# QEMU + virgl on macOS (Apple Silicon / Intel)

Build QEMU 10.x with **virglrenderer** GPU acceleration on macOS, from scratch.
No third-party taps. No outdated formulas. Just upstream sources and proper engineering.

## What this builds

| Component | Version | Source |
|---|---|---|
| **QEMU** | 10.2.50 (main) | https://gitlab.com/qemu-project/qemu |
| **virglrenderer** | 1.3.0+ (main) | https://gitlab.freedesktop.org/virgl/virglrenderer |
| **libepoxy** | 1.5.11 (main) | https://github.com/anholt/libepoxy |
| **SDL2** | 2.x (SDL2 branch) | https://github.com/libsdl-org/SDL |

GPU backend chain: **virtio-gpu-gl** → virglrenderer (EGL + Venus) → Mesa EGL → MoltenVK → **Metal**

## Prerequisites

```bash
brew install meson ninja pkg-config cmake
brew install glib pixman libepoxy
brew install libslirp lzo snappy gnutls nettle libusb vde spice-protocol
brew install mesa molten-vk vulkan-headers vulkan-loader
brew install libssh jpeg-turbo
```

> **Important**: GNU binutils is incompatible with macOS `ld`. If you have it installed,
> ensure `/usr/bin` appears before `/opt/homebrew/opt/binutils/bin` in your PATH,
> or the build scripts handle it automatically via hardcoded `/usr/bin/ar` and `/usr/bin/ranlib`.

> **Do NOT** `brew install sdl2` — the homebrew SDL2 uses Apple's broken OpenGL.framework
> (crashes on macOS 26.1). We build SDL2 from source with EGL support.

## Build

```bash
git clone https://github.com/adi/qemu-virgl.git
cd qemu-virgl

# Clone upstream sources
git clone https://github.com/anholt/libepoxy.git
git clone https://gitlab.freedesktop.org/virgl/virglrenderer.git
git clone https://gitlab.com/qemu-project/qemu.git --depth=1
git clone https://github.com/libsdl-org/SDL.git --branch SDL2 SDL

# Build everything
./build.sh
```

The first build takes ~10-15 minutes. Subsequent builds are incremental.

## Run a VM

```bash
# Create a disk image
./install/bin/qemu-img create -f qcow2 mydisk.qcow2 40G

# Boot an ISO to install Linux
./run-vm.sh mydisk.qcow2 -cdrom /path/to/linux.iso -boot d

# Boot installed system
./run-vm.sh mydisk.qcow2
```

The VM uses `virtio-gpu-gl` with SDL display and OpenGL ES enabled (`-display sdl,gl=es`).

## What was fixed / why it works

### Problem 1: libepoxy hardcodes `PLATFORM_HAS_EGL 0` on macOS

`libepoxy/src/dispatch_common.h` has:
```c
#elif defined(__APPLE__)
#define PLATFORM_HAS_EGL 0   // ← hardcoded, ignores ENABLE_EGL
```
**Fix**: Changed to `ENABLE_EGL` — Mesa 26 provides working EGL on macOS.

### Problem 2: libepoxy missing `EGL_LIB` for macOS

`dispatch_common.c` defines `EGL_LIB` for every platform except macOS.
**Fix**: Added `#define EGL_LIB "libEGL.dylib"` (points to Mesa's libEGL).

### Problem 3: virglrenderer uses Linux-only APIs

- `sys/signalfd.h` — Linux only; guarded with `#ifndef __APPLE__`
- `SOCK_CLOEXEC` — not on macOS; emulated with `fcntl(F_SETFD, FD_CLOEXEC)`
- `MSG_CMSG_CLOEXEC` — not on macOS; defined as `0`
- `clock_nanosleep` — not in macOS SDK; emulated with `nanosleep`
- `threads.h` (C11) — not in Xcode Clang; shim provided via `macos-compat/include/threads.h`

### Problem 4: GNU binutils in PATH

If `binutils` is installed via Homebrew, GNU `ar` and `ranlib` appear first in PATH.
GNU `ar` creates GNU-format archives that macOS `ld` cannot read.
**Fix**: Build scripts explicitly use `/usr/bin/ar` and `/usr/bin/ranlib`.
Additionally, meson's `-D` (deterministic) flag for `ar` is macOS-incompatible; stripped from build rules.

### Problem 5: macOS `ar` doesn't support response files (`@file`)

Meson uses `STATIC_LINKER_RSP` with `ar $flags $out @$out.rsp` for large libraries.
**Fix**: `macos-compat/ar-wrapper.sh` expands the response file before passing to ar.

### Problem 6: libepoxy loads Apple's libGL.dylib → crash in glGetString

libepoxy's `dispatch_common.c` defines `OPENGL_LIB` as Apple's OpenGL.framework on macOS.
When `epoxy_is_desktop_gl()` calls `glGetString(GL_VERSION)` via Apple's libGL, it crashes
at NULL+offset (`0x3b0`) because there is no Apple CGL context active.
**Fix**: Changed `OPENGL_LIB` (and all GLES/EGL lib paths) to point to Mesa's dylibs in
`/opt/homebrew/Cellar/mesa/26.0.0/lib/`.

### Problem 8: Apple OpenGL.framework crashes on macOS 26.1 (SDL2/CGL)

The homebrew SDL2 uses Apple's deprecated CGL (Core OpenGL) backend.
On macOS 26.1, `CGLChoosePixelFormat` crashes with a fatal address sentinel (`0xbad4007`).
**Fix**: Build SDL2 from source with `SDL_OPENGLES=ON` which selects Mesa EGL instead of CGL.
Use `-display sdl,gl=es` when launching QEMU.

### Problem 9: QEMU linker can't find `libsnappy`/`libfdt`

Meson generates per-target `LINK_ARGS` that lack `-L/opt/homebrew/lib`, while bare `-lsnappy`
and `-lfdt` appear in `$in` (which comes before `LINK_ARGS` in the linker command).
macOS ld requires `-L` to precede any `-l` that uses it.
**Fix**: The build script patches `build.ninja` to:
1. Move `LINK_ARGS` before `$in` in the linker command template
2. Prepend `-L` paths to the per-target `LINK_ARGS` of executable targets

### Problem 10: QEMU SDL2 creates desktop GL context instead of GLES for winctx

`sdl2_window_create` called `SDL_GL_SetAttribute` (profile=ES, version=3.0) after
`SDL_CreateWindow`, but EGL on macOS chooses its framebuffer config at window-creation
time — not at `SDL_GL_CreateContext` time. Setting attributes too late causes
`SDL_GL_CreateContext` to silently return NULL, leaving no current context.
All subsequent GL calls fail with "glCreateShader called without a rendering context",
reported by Mesa as "compile vertex error (null)".
**Fix**: Move `SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES)`
and version attributes to BEFORE `SDL_CreateWindow` in `ui/sdl2.c`.

## Architecture

```
Guest (Linux VM)
  └─ virtio-gpu-gl driver
       └─ virgl / venus protocol

Host (macOS)
  └─ QEMU virtio-gpu-gl device
       └─ virglrenderer 1.3.0
            ├─ EGL context (Mesa 26 libEGL)
            │    └─ Vulkan backend (MoltenVK 1.4.0 → Metal)
            └─ Venus protocol (Vulkan passthrough via MoltenVK)
```
