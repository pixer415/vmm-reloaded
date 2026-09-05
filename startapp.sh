#!/bin/bash
# Run the broadwayd daemon and point nginx to it
/usr/local/bin/start

# Note: No X server or wayland support--only cli and gtk3
# ↓↓↓ PUT COMMANDS HERE ↓↓↓

LIB=/usr/local/lib/virt-reloaded
RUNDIR=/run/virt-reloaded
mkdir -p "$RUNDIR"

RENDERNODE_REQUESTED="${RENDERNODE:-}"
RENDERNODE=""

# shellcheck source=src/gpu.sh
. "$LIB/gpu.sh"
# shellcheck source=src/libvirt.sh
. "$LIB/libvirt.sh"

# Find the GPU first: libvirt's qemu.conf needs the render node path baked into
# its device ACL before the daemon starts.
case "${GPU^^}" in
  Y|YES|TRUE|1|ON )
    if gpu_detect; then
      gpu_log "using $RENDERNODE ($(gpu_vendor_name "$GPU_VENDOR"))"
      echo "$RENDERNODE" > "$RUNDIR/rendernode"
    else
      gpu_log "no hardware rendering: $GPU_REASON"
      gpu_log "guests will fall back to software rendering"
    fi ;;
  * )
    gpu_log "GPU acceleration disabled (GPU=$GPU)" ;;
esac

LOCAL_LIBVIRT=0

case "${LIBVIRTD^^}" in
  Y|YES|TRUE|1|ON )
    if libvirt_socket_is_foreign; then
      libvirt_log "$LIBVIRT_SOCK is already bind-mounted, using that daemon instead"
      LOCAL_LIBVIRT=1
    elif libvirt_start; then
      LOCAL_LIBVIRT=1
      case "${LIBVIRT_NETWORK^^}" in
        Y|YES|TRUE|1|ON ) libvirt_start_network ;;
      esac
    fi ;;
  * )
    libvirt_log "not starting a local libvirtd (LIBVIRTD=$LIBVIRTD)" ;;
esac

# A local daemon with no connection configured would open on an empty window.
if [ "$LOCAL_LIBVIRT" = 1 ] && { [ -z "$HOSTS" ] || [ "${HOSTS// /}" = "[]" ]; }; then
  HOSTS="['qemu:///system']"
fi

dbus-launch gsettings set org.virt-manager.virt-manager.connections uris "$HOSTS"
dbus-launch gsettings set org.virt-manager.virt-manager.connections autoconnect "$HOSTS"
dbus-launch gsettings set org.virt-manager.virt-manager xmleditor-enabled true
tmux send-keys -t ttyd dbus-launch\ virt-manager\ --no-fork Enter
trap 'exit 0' SIGTERM
while true; do sleep 1; done
