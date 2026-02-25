#!/bin/bash
# Launch a Linux VM with virgl GPU acceleration on macOS (Apple Silicon / Intel)
# Requires: a Linux disk image and OVMF firmware or SeaBIOS
#
# Usage: ./run-vm.sh <disk-image.qcow2>

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/install"
QEMU="$INSTALL/bin/qemu-system-x86_64"

# Export library search path so dylibs are found
export DYLD_LIBRARY_PATH="$INSTALL/lib:/opt/homebrew/Cellar/mesa/26.0.0/lib:$DYLD_LIBRARY_PATH"

# Use Mesa (Vulkan/kosmickrisp on Apple Silicon, lavapipe as fallback) for EGL
export VK_ICD_FILENAMES="/opt/homebrew/Cellar/molten-vk/1.4.0/etc/vulkan/icd.d/MoltenVK_icd.json"

DISK="$1"
if [ -z "$DISK" ]; then
    echo "Usage: $0 <disk-image.qcow2>"
    echo ""
    echo "Create a disk image with:"
    echo "  $INSTALL/bin/qemu-img create -f qcow2 disk.qcow2 40G"
    exit 1
fi
shift

# RAM and CPU
RAM=${RAM:-4G}
CPUS=${CPUS:-4}

# Use Apple Hypervisor (hvf) when available; otherwise fall back to TCG.
if "$QEMU" -accel help 2>/dev/null | grep -Eq '(^|[[:space:]])hvf([[:space:]]|$)'; then
    ACCEL="hvf"
    CPU_MODEL="host"
else
    ACCEL="tcg"
    CPU_MODEL="max"
fi

# Pick network backend
NETDEV="-netdev user,id=net0 -device virtio-net-pci,netdev=net0"

exec "$QEMU" \
    -machine q35,accel=$ACCEL \
    -cpu "$CPU_MODEL" \
    -smp $CPUS \
    -m $RAM \
    -device virtio-gpu-gl,xres=1920,yres=1080 \
    -display sdl,gl=es \
    -drive file="$DISK",if=virtio,format=qcow2 \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    $NETDEV \
    -usb \
    "$@"
