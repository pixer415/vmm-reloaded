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

# virt-manager runs in the foreground of the tmux session that ttyd shows, so
# that its SSH password prompts are reachable from the terminal tile. That also
# means window 0 is not a usable shell: anything typed there goes to
# virt-manager's stdin and looks like a terminal with no prompt. Give the tile a
# second window that really is a shell, and turn the status bar on so both are
# visible and switchable.
tmux send-keys -t ttyd:0 dbus-launch\ virt-manager\ --no-fork Enter
tmux rename-window -t ttyd:0 virt-manager
tmux new-window -t ttyd: -n shell
tmux set -t ttyd -g status on
tmux set -t ttyd -g mouse on
# Flag the virt-manager window when it wants attention, e.g. a password prompt.
tmux set -t ttyd -g monitor-activity on
tmux set -t ttyd -g visual-activity off
# Open on the shell: that is what someone clicking a terminal icon is after.
tmux select-window -t ttyd:shell

trap 'exit 0' SIGTERM
while true; do sleep 1; done
