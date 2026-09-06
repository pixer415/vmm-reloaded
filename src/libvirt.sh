#!/usr/bin/env bash
# Bring up a libvirtd inside the container and point it at the render node that
# gpu.sh found, so that virt-manager's "3D acceleration" and "OpenGL" boxes are
# backed by a QEMU that actually has the GL devices compiled in.
#
# Sourced by startapp.

LIBVIRT_SOCK="/var/run/libvirt/libvirt-sock"
LIBVIRT_QEMU_CONF="${LIBVIRT_QEMU_CONF:-/etc/libvirt/qemu.conf}"
LIBVIRTD_CONF="${LIBVIRTD_CONF:-/etc/libvirt/libvirtd.conf}"
LIBVIRT_MANAGED_BEGIN="# >>> docker-virt-reloaded >>>"
LIBVIRT_MANAGED_END="# <<< docker-virt-reloaded <<<"

libvirt_log() { echo "[libvirt] $*"; }

# Replace our block in one of libvirt's config files, so restarts stay
# idempotent and anything the user added by hand survives.
libvirt_replace_block() {

  local conf="$1"

  [ -f "$conf" ] || touch "$conf"
  sed -i "\|^${LIBVIRT_MANAGED_BEGIN}\$|,\|^${LIBVIRT_MANAGED_END}\$|d" "$conf"

  {
    echo "$LIBVIRT_MANAGED_BEGIN"
    cat
    echo "$LIBVIRT_MANAGED_END"
  } >> "$conf"
}

# True only when the host really did bind-mount its socket in. A bind mount is
# a mount point; a socket our own previous run left behind is not. The two look
# identical to a plain [ -S ] test, and mistaking one for the other means never
# starting a daemon at all.
libvirt_socket_is_bind_mounted() {
  awk '{print $5}' /proc/self/mountinfo 2>/dev/null \
    | grep -qx -e /var/run/libvirt/libvirt-sock -e /run/libvirt/libvirt-sock
}

# Is anything actually behind the socket? A socket file with no daemon on the
# other end answers "Connection refused", which is exactly what a restarted
# container finds sitting in /run from its previous life.
libvirt_daemon_responds() {
  virsh -c qemu:///system version >/dev/null 2>&1
}

# /run is part of the container's writable layer, so sockets and pidfiles
# outlive a restart. libvirtd will not start while a stale pidfile still claims
# the lock, and the dead sockets confuse everything that tries to connect.
libvirt_clear_stale_runtime() {

  rm -f /var/run/libvirt/libvirt-sock \
        /var/run/libvirt/libvirt-sock-ro \
        /var/run/libvirt/libvirt-admin-sock \
        /var/run/libvirt/virtlogd-sock \
        /var/run/libvirt/virtlogd-admin-sock \
        /var/run/libvirtd.pid \
        /var/run/virtlogd.pid 2>/dev/null || true

  # Per-domain state for guests that died with the previous container. Leaving
  # these makes libvirt believe those domains are still running.
  rm -f /var/run/libvirt/qemu/*.pid 2>/dev/null || true
}

# Rewrite our block in qemu.conf. Everything here exists because libvirt makes
# assumptions that only hold on a systemd host with its own cgroup tree.
libvirt_write_qemu_conf() {

  local rendernode="${1:-}"
  local acl='"/dev/null", "/dev/full", "/dev/zero", "/dev/random", "/dev/urandom", "/dev/ptmx", "/dev/kvm"'

  if [ -n "$rendernode" ]; then
    acl="$acl, \"$rendernode\""
    [ -n "${GPU_CARD:-}" ] && acl="$acl, \"$GPU_CARD\""
  fi

  libvirt_replace_block "$LIBVIRT_QEMU_CONF" <<EOF
# AppArmor/SELinux confinement cannot be applied from inside a container.
security_driver = "none"

# Run QEMU as root: the container has no matching "render"/"kvm" group ids from
# the host, so this is the reliable way to let QEMU open the DRM render node.
user = "root"
group = "root"
dynamic_ownership = 0
remember_owner = 0

# Docker already gives us a private /dev and no delegated cgroup tree; letting
# libvirt build its own on top of that just breaks domain startup.
namespaces = []
cgroup_controllers = []

# Devices libvirt is allowed to hand to a guest. The render node has to be in
# here or SPICE/egl-headless GL fails with a permission error at boot.
cgroup_device_acl = [ $acl ]
EOF
}

# libvirtd defaults to polkit on the read-write socket, and there is no polkitd
# in this container. Everything here runs as root behind the socket's own 0700
# permissions, so authenticate on those instead.
libvirt_write_daemon_conf() {

  libvirt_replace_block "$LIBVIRTD_CONF" <<'EOF'
auth_unix_ro = "none"
auth_unix_rw = "none"
listen_tls = 0
listen_tcp = 0
EOF
}

# A bind-mounted /etc/libvirt/qemu arrives empty - Docker only seeds *named*
# volumes from the image - which would leave libvirt with no "default" network
# and no saved domains. Put back whatever is missing, clobbering nothing.
libvirt_seed_config() {

  local skel="/usr/local/share/virt-reloaded/qemu-skel"

  [ -d "$skel" ] || return 0
  mkdir -p /etc/libvirt/qemu
  cp -a -n "$skel"/. /etc/libvirt/qemu/ 2>/dev/null || true
}

libvirt_start() {

  mkdir -p /var/run/libvirt /var/log/libvirt /var/lib/libvirt/images /var/cache/libvirt 2>/dev/null || true
  libvirt_seed_config
  libvirt_clear_stale_runtime

  if ! command -v libvirtd >/dev/null 2>&1; then
    libvirt_log "libvirtd is not installed, skipping"
    return 1
  fi

  libvirt_write_qemu_conf "${RENDERNODE:-}"
  libvirt_write_daemon_conf

  # virtlogd owns the guests' serial/console logs; libvirtd refuses to start a
  # domain without it.
  if ! pgrep -x virtlogd >/dev/null 2>&1; then
    virtlogd -d 2>/dev/null || libvirt_log "virtlogd failed to start"
  fi

  libvirtd -d || { libvirt_log "libvirtd failed to start"; return 1; }

  local i
  for i in $(seq 1 30); do
    [ -S "$LIBVIRT_SOCK" ] && break
    sleep 0.5
  done

  if [ ! -S "$LIBVIRT_SOCK" ]; then
    libvirt_log "timed out waiting for $LIBVIRT_SOCK"
    return 1
  fi

  libvirt_log "libvirtd is up on qemu:///system"
  return 0
}

# The default NAT network needs NET_ADMIN and /dev/net/tun. Both are optional
# additions to the compose file, so never treat a failure here as fatal.
libvirt_start_network() {

  virsh -c qemu:///system net-info default >/dev/null 2>&1 || {
    libvirt_log "no 'default' network defined, skipping"
    return 0
  }

  if virsh -c qemu:///system net-list --name 2>/dev/null | grep -qx "default"; then
    return 0
  fi

  virsh -c qemu:///system net-autostart default >/dev/null 2>&1 || true

  if virsh -c qemu:///system net-start default >/dev/null 2>&1; then
    libvirt_log "started the 'default' NAT network"
  else
    libvirt_log "could not start the 'default' network - add 'cap_add: [NET_ADMIN]' and 'devices: [/dev/net/tun]' to your compose file if guests need NAT"
  fi

  return 0
}
