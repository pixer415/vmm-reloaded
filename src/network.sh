#!/usr/bin/env bash
# Put guests directly on the LAN, so the router gives them their own addresses.
#
# libvirt's NAT network needs to write /proc/sys, which Docker mounts read-only.
# This takes the other route entirely: a plain Linux bridge that we build here,
# with a dedicated uplink interface enslaved to it, and a libvirt network in
# "bridge" forward mode pointing at it. libvirt then only adds guest taps - it
# manages no addresses, no dnsmasq and no firewall rules, so it never touches a
# sysctl and needs no privilege beyond NET_ADMIN.
#
# The uplink has to be a macvlan in *passthru* mode. In the default bridge mode
# a macvlan only accepts frames addressed to its own MAC, so traffic coming back
# to a guest's MAC is dropped; passthru hands the container the whole NIC and
# permits arbitrary source MACs, which is what bridging guests requires.
#
# Sourced by startapp.

: "${VM_BRIDGE_NAME:=br-lan}"

net_log() { echo "[net] $*"; }

net_is_macvlan() {
  ip -d link show "$1" 2>/dev/null | grep -q 'macvlan'
}

# Find the interface Docker gave us for the macvlan network.
#
# Identify it by what it *is*, not by which one lacks a default route: when a
# container joins both a bridge and a macvlan network, Docker may put the
# default route on the macvlan, and a route-based guess would then pick the
# bridge interface and enslave the container's own lifeline.
net_find_uplink() {

  local dev default_dev fallback=""

  default_dev="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"

  for dev in /sys/class/net/*; do
    dev="${dev##*/}"
    case "$dev" in
      lo | "$VM_BRIDGE_NAME" | virbr* | vnet* | veth* | docker* | br-* ) continue ;;
    esac

    if net_is_macvlan "$dev"; then
      echo "$dev"
      return 0
    fi

    # Only as a fallback, and only for something that is not the way out.
    [ -z "$fallback" ] && [ "$dev" != "$default_dev" ] && fallback="$dev"
  done

  [ -n "$fallback" ] && { echo "$fallback"; return 0; }
  return 1
}

# Enslaving an interface means giving up its address, so make sure the container
# still has a way out before we do that to it.
net_has_other_route() {

  local uplink="$1" default_dev

  default_dev="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  [ -n "$default_dev" ] && [ "$default_dev" != "$uplink" ]
}

net_build_bridge() {

  local uplink="$1"
  local bridge="$VM_BRIDGE_NAME"

  if ! net_has_other_route "$uplink"; then
    net_log "refusing to enslave '$uplink': it carries this container's only route"
    net_log "either the app is not also on its normal bridge network, or Docker put"
    net_log "the default route on the macvlan - check 'ip route' inside the container"
    return 1
  fi

  if ! ip link show "$bridge" >/dev/null 2>&1; then
    if ! ip link add "$bridge" type bridge 2>/dev/null; then
      net_log "could not create bridge '$bridge' - is the 'bridge' module loaded on the host?"
      return 1
    fi
  fi

  # A bridge port must not carry an address of its own. Docker assigns one from
  # the macvlan network's subnet; we do not need it, the guests do.
  ip -4 addr flush dev "$uplink" 2>/dev/null || true

  if ! ip link set "$uplink" master "$bridge" 2>/dev/null; then
    net_log "could not enslave '$uplink' to '$bridge'"
    net_log "the macvlan network must use 'macvlan_mode: passthru'"
    return 1
  fi

  ip link set "$uplink" up 2>/dev/null || true
  ip link set "$bridge" up 2>/dev/null || true

  net_log "bridge '$bridge' is up with '$uplink' as its uplink"
  return 0
}

# A libvirt network in bridge mode is just a name pointing at a bridge we own.
# libvirt adds guest taps to it and does nothing else, which is the whole point.
net_define_libvirt_network() {

  local name="lan"
  local bridge="$VM_BRIDGE_NAME"
  local xml

  xml="$(mktemp --suffix=.xml)"
  cat > "$xml" <<EOF
<network>
  <name>$name</name>
  <forward mode='bridge'/>
  <bridge name='$bridge'/>
</network>
EOF

  # Redefining is harmless and keeps the definition matching the bridge name if
  # someone changes VM_BRIDGE_NAME between restarts.
  if ! virsh -c qemu:///system net-define "$xml" >/dev/null 2>&1; then
    net_log "could not define the '$name' libvirt network"
    rm -f "$xml"
    return 1
  fi
  rm -f "$xml"

  virsh -c qemu:///system net-autostart "$name" >/dev/null 2>&1 || true

  if virsh -c qemu:///system net-list --name 2>/dev/null | grep -qx "$name"; then
    net_log "the '$name' network is already active"
    return 0
  fi

  local err
  if err="$(virsh -c qemu:///system net-start "$name" 2>&1)"; then
    net_log "started the '$name' network - guests on it get addresses from your router"
  else
    net_log "could not start the '$name' network:"
    while IFS= read -r line; do
      [ -n "$line" ] && net_log "  $line"
    done <<< "$err"
    return 1
  fi

  return 0
}

net_setup() {

  local uplink="${VM_BRIDGE_UPLINK:-}"

  if [ -z "$uplink" ]; then
    if ! uplink="$(net_find_uplink)"; then
      net_log "no spare interface found for the guest bridge"
      net_log "attach the app to a macvlan network as well, or set VM_BRIDGE_UPLINK"
      return 1
    fi
    net_log "using '$uplink' as the guest uplink (set VM_BRIDGE_UPLINK to override)"
  elif [ ! -d "/sys/class/net/$uplink" ]; then
    net_log "VM_BRIDGE_UPLINK='$uplink' does not exist in this container"
    return 1
  fi

  net_build_bridge "$uplink" || return 1
  net_define_libvirt_network || return 1

  return 0
}
