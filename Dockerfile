FROM mber5/broadway-baseimage:latest

ENV FAVICON_URL='https://raw.githubusercontent.com/virt-manager/virt-manager/931936a328d22413bb663e0e21d2f7bb111dbd7c/data/icons/256x256/apps/virt-manager.png'
ENV APP_TITLE='Virtual Machine Manager'
ENV CORNER_IMAGE_URL='https://raw.githubusercontent.com/virt-manager/virt-manager/931936a328d22413bb663e0e21d2f7bb111dbd7c/data/icons/256x256/apps/virt-manager.png'
ENV HOSTS="[]"

# Run libvirtd inside the container so that virt-manager drives a QEMU that was
# built with the OpenGL/virgl modules. Set LIBVIRTD=N to keep the original
# behaviour of only talking to a bind-mounted or remote libvirtd.
ENV LIBVIRTD="Y"
# Hardware rendering for the guests. Requires /dev/dri in the devices section.
ENV GPU="Y"
# Pin a specific DRM render node, e.g. /dev/dri/renderD129. Empty = autodetect.
ENV RENDERNODE=""
# Start libvirt's "default" NAT network. Needs cap_add NET_ADMIN + /dev/net/tun.
ENV LIBVIRT_NETWORK="Y"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

# dpkg must not try to start services while we are building an image.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

RUN apt-get update

RUN apt-get install -y --no-install-recommends virt-manager dbus-x11 libglib2.0-bin gir1.2-spiceclientgtk-3.0 ssh at-spi2-core

# QEMU plus the two module packages that carry virtio-vga-gl and ui-egl-headless,
# which is what libvirt probes for before it accepts <acceleration accel3d='yes'/>.
RUN apt-get install -y --no-install-recommends \
      qemu-system-x86 \
      qemu-system-modules-opengl \
      qemu-system-modules-spice \
      qemu-utils \
      ovmf \
      seabios \
      ipxe-qemu \
      swtpm \
      swtpm-tools

RUN apt-get install -y --no-install-recommends \
      libvirt-daemon-system \
      libvirt-daemon-driver-qemu \
      libvirt-clients \
      dnsmasq-base \
      iptables \
      iproute2 \
      netcat-openbsd

# Host-side GL stack. Without virglrenderer + EGL/GBM, QEMU has the -gl devices
# but fails at boot with "egl: render node init failed".
RUN apt-get install -y --no-install-recommends \
      libvirglrenderer1 \
      libegl1 \
      libegl-mesa0 \
      libgbm1 \
      libgl1 \
      libglx-mesa0 \
      libgl1-mesa-dri \
      libvulkan1 \
      mesa-vulkan-drivers \
      libepoxy0 \
      libdrm2 \
      pciutils

# Diagnostics only; never fail the build over them.
RUN apt-get install -y --no-install-recommends mesa-utils-bin vulkan-tools || true

RUN apt-get clean && apt-get autoclean && rm -rf /var/lib/apt/lists/* && rm -f /usr/sbin/policy-rc.d

# Keep a pristine copy of libvirt's config tree. A bind-mounted /etc/libvirt/qemu
# (what ZimaOS and most NAS front-ends use) arrives empty, and startapp restores
# the default network and any missing pieces from here.
RUN mkdir -p /usr/local/share/virt-reloaded && cp -a /etc/libvirt/qemu /usr/local/share/virt-reloaded/qemu-skel

RUN mkdir -p /root/.ssh
RUN echo "Host *\n\tStrictHostKeyChecking no\n" >> /root/.ssh/config

COPY src/ /usr/local/lib/virt-reloaded/
COPY startapp.sh /usr/local/bin/startapp

# Checkouts on Windows hand us CRLF, which a Linux shebang line will not survive.
RUN sed -i 's/\r$//' /usr/local/bin/startapp /usr/local/lib/virt-reloaded/* \
 && chmod 755 /usr/local/bin/startapp /usr/local/lib/virt-reloaded/* \
 && ln -sf /usr/local/lib/virt-reloaded/virt-3d /usr/local/bin/virt-3d \
 && ln -sf /usr/local/lib/virt-reloaded/virt-gpu-check /usr/local/bin/virt-gpu-check

CMD ["/usr/local/bin/startapp"]
