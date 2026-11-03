#!/bin/bash
# Container start: find the way to the GPU, prepare /data, then run the server as a normal user.
#
# Environment:
#   SPLAT_VULKAN_DRIVER  auto (default) | wsl | nvidia | mesa | cpu
#   ALLOW_CPU=1          no GPU found: run on the CPU (lavapipe) instead of stopping. For trying things out.
#   SPLAT_SKIP_GPU_CHECK=1  do not ask Vulkan for a device before starting
#   SPLAT_UID, SPLAT_GID user the server runs as when the container starts as root (default 1000)
#   SPLAT_FRAME_KEY      private SSH key for the Frame (default /run/secrets/frame_key)
#   SPLAT_PIPELINE       the Arcturus scripts (default /opt/pipeline)
#   SPLAT_WSL_MOUNT      the host's /usr/lib/wsl, needed under WSL (default /wsl)
#   SPLAT_SYSROOT, SPLAT_DATA  other locations for /, /data: only the tests set these
set -euo pipefail

ROOT=${SPLAT_SYSROOT:-}
DATA=${SPLAT_DATA:-/data}
WSL_MOUNT=$ROOT${SPLAT_WSL_MOUNT:-/wsl}
ICD_DIR=$ROOT/usr/share/vulkan/icd.d
APP=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)

die() { echo "splat-workshop: $*" >&2; exit 1; }
say() { echo "splat-workshop: $*"; }

nvidia_icd() {
    local f
    for f in "$ROOT"/etc/vulkan/icd.d/nvidia_icd*.json "$ICD_DIR"/nvidia_icd*.json; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

choose_driver() {
    case ${SPLAT_VULKAN_DRIVER:-auto} in
        wsl|nvidia|mesa|cpu) echo "$SPLAT_VULKAN_DRIVER"; return ;;
        auto) ;;
        *) die "SPLAT_VULKAN_DRIVER must be auto, wsl, nvidia, mesa or cpu" ;;
    esac
    if [ -e "$ROOT/dev/dxg" ]; then echo wsl
    elif [ -e "$ROOT/dev/nvidiactl" ] || nvidia_icd >/dev/null; then echo nvidia
    elif [ -d "$ROOT/dev/dri" ]; then echo mesa
    elif [ "${ALLOW_CPU:-0}" = 1 ]; then echo cpu
    else die "no GPU in this container. NVIDIA: --gpus all. AMD or Intel: --device /dev/dri.
WSL: --device /dev/dxg and -v /usr/lib/wsl:/wsl:ro. To run on the CPU anyway: ALLOW_CPU=1."
    fi
}

# NVIDIA's D3D12 driver under WSL opens its libraries by the full path /usr/lib/wsl/lib, and D3D12 looks for
# every GPU's driver in /usr/lib/wsl/drivers: Dozen stops altogether if one of them is missing, also the iGPU's.
link_wsl_libraries() {
    [ -e "$WSL_MOUNT/lib/libd3d12.so" ] ||
        die "WSL: $WSL_MOUNT/lib/libd3d12.so not found. Mount the host's /usr/lib/wsl: -v /usr/lib/wsl:/wsl:ro"
    local sub entry
    for sub in lib drivers; do
        mkdir -p "$ROOT/usr/lib/wsl/$sub"
        for entry in "$WSL_MOUNT/$sub"/*; do
            [ -e "$ROOT/usr/lib/wsl/$sub/${entry##*/}" ] || ln -s "$entry" "$ROOT/usr/lib/wsl/$sub/${entry##*/}"
        done
    done
}

set_driver() {
    local files=""
    case $1 in
        wsl)
            say "WARNING: under WSL, Spirula's training crashes in Mesa's Dozen driver. Conversions stop there. See docs/container.md."
            link_wsl_libraries
            export LD_LIBRARY_PATH=$ROOT/usr/lib/wsl/lib
            files=$ICD_DIR/dzn_icd.json ;;
        nvidia)
            files=$(nvidia_icd) || die "NVIDIA GPU found, but no Vulkan driver in the container: its capabilities must
include graphics. Set NVIDIA_DRIVER_CAPABILITIES=all."
            ;;
        cpu)
            files=$ICD_DIR/lvp_icd.json ;;
        mesa) ;;                # Mesa's drivers find their GPUs by themselves
    esac
    if [ -n "$files" ]; then
        export VK_DRIVER_FILES=$files VK_ICD_FILENAMES=$files
    fi
}

# Better to stop here than an hour into a conversion
check_device() {
    [ "${SPLAT_SKIP_GPU_CHECK:-0}" = 1 ] && return 0
    local info gpus
    info=$(vulkaninfo --summary 2>/dev/null) || die "Vulkan cannot start with driver '$1'. Details: vulkaninfo --summary"
    gpus=$(echo "$info" | awk '/deviceType/ {t = $NF} /deviceName/ {sub(/^[^=]*= */, ""); print t ": " $0}')
    [ -n "$gpus" ] || die "Vulkan with driver '$1' lists no device"
    say "Vulkan devices:"
    echo "$gpus"
    if [ "$1" != cpu ] && ! echo "$gpus" | grep -qE '_(DISCRETE|INTEGRATED|VIRTUAL)_GPU'; then
        die "Vulkan with driver '$1' only offers the CPU. To run on the CPU anyway: ALLOW_CPU=1."
    fi
}

check_spirula_revision() {
    local readme=$ROOT${SPLAT_PIPELINE:-/opt/pipeline}/README.md have want
    [ -f "$readme" ] || { say "the Arcturus scripts are not there yet: mount them at ${SPLAT_PIPELINE:-/opt/pipeline}"; return 0; }
    have=$(cat "$ROOT/opt/spirula/REVISION" 2>/dev/null || true)
    want=$(grep -oE 'spirula-studio checkout [0-9a-f]{40}' "$readme" | head -1 | awk '{print $3}' || true)
    if [ -n "$want" ] && [ "$want" != "$have" ]; then
        say "WARNING: the pipeline is tested with Spirula $want, this image has ${have:-an unknown one}."
        say "         Rebuild with --build-arg SPIRULA_REV=$want if conversions fail."
    fi
}

prepare_data() {
    export HOME=$DATA/home
    mkdir -p "$DATA/recordings" "$DATA/runs" "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    [ -f "$DATA/config.toml" ] || cp "$APP/docker/config.toml" "$DATA/config.toml"
    local key=$ROOT${SPLAT_FRAME_KEY:-/run/secrets/frame_key}
    if [ -f "$key" ]; then
        # A copy: ssh refuses a key that others can read or that belongs to someone else
        cp "$key" "$HOME/.ssh/frame_key"
        chmod 600 "$HOME/.ssh/frame_key"
        printf 'Host *\n    IdentityFile %s\n    StrictHostKeyChecking accept-new\n' "$HOME/.ssh/frame_key" > "$HOME/.ssh/config"
    fi
}

drop_to_user() {
    [ "$(id -u)" = 0 ] || return 0
    local uid=${SPLAT_UID:-1000} gid=${SPLAT_GID:-1000} groups dev
    groups=$gid
    [ "$(stat -c %u "$DATA")" = "$uid" ] || chown -R "$uid:$gid" "$DATA"
    chown -R "$uid:$gid" "$HOME"
    # The groups that may use the GPU differ from host to host
    for dev in /dev/dri/* /dev/dxg; do
        [ -e "$dev" ] && groups=$groups,$(stat -c %g "$dev")
    done
    exec setpriv --reuid "$uid" --regid "$gid" --groups "$groups" "$@"
}

driver=$(choose_driver)
say "Vulkan driver: $driver"
set_driver "$driver"
check_device "$driver"
check_spirula_revision
prepare_data
drop_to_user "$@"
exec "$@"
