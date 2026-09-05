#!/usr/bin/env bash
# Locate a DRM render node that QEMU can render on, and make sure the device
# nodes actually exist inside the container.
#
# This mirrors what dockur/chromeos inherits from qemus/qemu's src/display.sh:
# walk /dev/dri/renderD*, keep the first node that is a real character device we
# can open and whose PCI vendor is one Mesa has a driver for, then recreate any
# node that the runtime exposed to the cgroup but did not materialise in /dev.
#
# Sourced by startapp; sets RENDERNODE, GPU_CARD, GPU_VENDOR and GPU_REASON.

GPU_CARD=""
GPU_VENDOR=""
GPU_REASON=""

gpu_log() { echo "[gpu] $*"; }

# Read the PCI vendor id of a render node, rejecting anything malformed,
# missing, unopenable, or already gone.
gpu_node_vendor() {

  local node="$1"
  local name="${node##*/}"

  [[ "$name" =~ ^renderD[0-9]{3}$ ]] || return 1
  (( 10#${name#renderD} >= 128 )) || return 1
  [ -c "$node" ] || return 1

  local fd
  { exec {fd}<>"$node"; } 2>/dev/null || return 1
  { exec {fd}>&-; } 2>/dev/null || true

  local vendor_file="/sys/class/drm/${name}/device/vendor"
  if [ -r "$vendor_file" ] && IFS= read -r GPU_VENDOR < "$vendor_file"; then
    GPU_VENDOR="${GPU_VENDOR,,}"
  else
    # WSL2 and some virtual DRM drivers expose no PCI vendor at all. Not a
    # reason to refuse the node, only a reason not to claim we know the GPU.
    GPU_VENDOR="unknown"
  fi

  return 0
}

gpu_vendor_name() {
  case "${1,,}" in
    "0x8086" ) echo "Intel" ;;
    "0x1002" ) echo "AMD" ;;
    "0x10de" ) echo "NVIDIA" ;;
    "0x1af4" ) echo "VirtIO" ;;
    "0x1414" ) echo "Microsoft (WSL)" ;;
    "unknown" | "" ) echo "unrecognised GPU" ;;
    * ) echo "unrecognised GPU, PCI vendor ${1}" ;;
  esac
}

# Recreate a missing device node. Docker hands the container permission through
# the device cgroup, but a node that was bind-mounted rather than passed with
# --device can be absent from /dev even though the major/minor are usable.
gpu_mknod() {

  local path="$1" minor="$2"

  [ -c "$path" ] && return 0
  mkdir -m 755 -p /dev/dri 2>/dev/null || true
  mknod "$path" c 226 "$minor" 2>/dev/null || return 1
  chmod 666 "$path" 2>/dev/null || true

  return 0
}

gpu_detect() {

  RENDERNODE=""
  GPU_REASON=""

  if [ ! -d /dev/dri ]; then
    GPU_REASON="'/dev/dri' is missing; add it to the devices section of your compose file"
    return 1
  fi

  if [ -n "${RENDERNODE_REQUESTED:-}" ]; then
    if ! gpu_node_vendor "$RENDERNODE_REQUESTED"; then
      GPU_REASON="render node '$RENDERNODE_REQUESTED' is unavailable or inaccessible"
      return 1
    fi
    RENDERNODE="$RENDERNODE_REQUESTED"
  else
    local node fallback=""
    for node in /dev/dri/renderD*; do
      gpu_node_vendor "$node" || continue
      case "$GPU_VENDOR" in
        "0x8086" | "0x1002" | "0x10de" )
          RENDERNODE="$node"
          break ;;
        * )
          [ -z "$fallback" ] && fallback="$node" ;;
      esac
    done
    if [ -z "$RENDERNODE" ] && [ -n "$fallback" ]; then
      RENDERNODE="$fallback"
      gpu_node_vendor "$RENDERNODE" || true
    fi
  fi

  if [ -z "$RENDERNODE" ]; then
    GPU_REASON="/dev/dri exists but holds no usable render node"
    return 1
  fi

  local name="${RENDERNODE##*/}"
  local minor="${name#renderD}"

  gpu_mknod "$RENDERNODE" "$((10#$minor))" || true

  # QEMU only opens the render node, but Mesa probes the matching card node on
  # some drivers, so create it when the numbering makes it predictable.
  GPU_CARD="/dev/dri/card$((10#$minor - 128))"
  gpu_mknod "$GPU_CARD" "$((10#$minor - 128))" || GPU_CARD=""

  # QEMU runs as root inside this container, but loosen the permissions anyway
  # so that a non-root qemu.conf user still reaches the node.
  chmod 666 "$RENDERNODE" 2>/dev/null || true
  [ -n "$GPU_CARD" ] && chmod 666 "$GPU_CARD" 2>/dev/null || true

  if ! gpu_node_vendor "$RENDERNODE"; then
    GPU_REASON="render node '$RENDERNODE' disappeared during setup"
    RENDERNODE=""
    return 1
  fi

  return 0
}
