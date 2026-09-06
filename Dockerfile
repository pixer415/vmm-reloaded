# syntax=docker/dockerfile:1

# mber5/broadway-baseimage:latest was built FROM ubuntu:latest back when that
# still meant 20.04, and the published image was never rebuilt. Focal has no
# qemu-system-modules-opengl, no swtpm, and a QEMU (4.2) far too old for the
# virgl work this fork exists to do.
#
# So: lift the Broadway glue out of that image - the nginx template, the start
# script, the ttyd binary - and rebuild everything else on a release that has
# the GL stack. Pinned to 24.04 rather than :latest so this cannot rot again.

FROM mber5/broadway-baseimage:latest AS broadway

FROM ubuntu:24.04

# Carried over from the base image, which no longer sets them for us.
ENV GDK_BACKEND='broadway'
ENV BROADWAY_DISPLAY=':5'
ENV GTK_THEME='Materia'
ENV BG_GRADIENT="#ddd, #999"
ENV DARK_MODE='false'

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
# Open the point-and-click acceleration window next to virt-manager. N hides it.
ENV ACCEL_GUI="Y"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

# dpkg must not try to start services while we are building an image.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

RUN apt-get update

# The Broadway runtime the base image used to provide. libgtk-3-bin brings both
# broadwayd and the GTK library, which is named libgtk-3-0t64 on 24.04 and may
# be renamed again; depending on the -bin package avoids chasing that.
RUN apt-get install -y --no-install-recommends \
      libgtk-3-bin \
      nginx \
      gettext-base \
      tmux \
      procps \
      materia-gtk-theme \
      papirus-icon-theme

# The Broadway page template rewrites the served HTML with sub_filter, which
# exists only if nginx was built --with-http_sub_module. Ubuntu's nginx-core
# normally is; fall back to nginx-extras rather than ship a silently broken UI,
# and fail the build outright if neither has it.
RUN if ! nginx -V 2>&1 | grep -q -- '--with-http_sub_module'; then \
      apt-get install -y --no-install-recommends nginx-extras; \
    fi \
 && nginx -V 2>&1 | grep -q -- '--with-http_sub_module'

RUN apt-get install -y --no-install-recommends virt-manager dbus-x11 libglib2.0-bin gir1.2-spiceclientgtk-3.0 ssh at-spi2-core python3-gi gir1.2-gtk-3.0

# GTK's icon and MIME plumbing. --no-install-recommends leaves these out, and
# without them virt-manager starts but logs "Could not load a pixbuf from icon
# theme" and renders without icons: Papirus ships SVG, which needs the librsvg
# pixbuf loader, and GTK wants a MIME database and a fallback icon theme.
RUN apt-get install -y --no-install-recommends \
      librsvg2-common \
      shared-mime-info \
      libgdk-pixbuf2.0-bin \
      adwaita-icon-theme \
      hicolor-icon-theme

# The package triggers normally rebuild these; do it explicitly in case a
# trigger was skipped, but never fail the build over a cache refresh.
RUN update-mime-database /usr/share/mime || true; \
    gdk-pixbuf-query-loaders --update-cache || true; \
    gtk-update-icon-cache -f /usr/share/icons/hicolor || true

# A person who opens the terminal tile expects a shell that can do something.
RUN apt-get install -y --no-install-recommends iputils-ping less nano curl

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
      nftables \
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

# The Broadway web front end: nginx page template, startup script, terminal icon,
# and the ttyd binary (statically linked, so the older build still runs here).
COPY --from=broadway /usr/local/bin/start /usr/local/bin/start
COPY --from=broadway /etc/nginx/nginx.tmpl /etc/nginx/nginx.tmpl
COPY --from=broadway /www/data/images/terminal-outline.svg /www/data/images/terminal-outline.svg
COPY --from=broadway /usr/bin/ttyd /usr/bin/ttyd
RUN chmod 755 /usr/local/bin/start /usr/bin/ttyd

# The base image shipped the light Materia variant under the plain name; keep
# that, but do not fail if the packaging ever drops the variant.
RUN if [ -d /usr/share/themes/Materia-light ]; then \
      rm -rf /usr/share/themes/Materia && \
      mv /usr/share/themes/Materia-light /usr/share/themes/Materia; \
    fi

# Keep a pristine copy of libvirt's config tree. A bind-mounted /etc/libvirt/qemu
# (what ZimaOS and most NAS front-ends use) arrives empty, and startapp restores
# the default network and any missing pieces from here.
RUN mkdir -p /usr/local/share/virt-reloaded && cp -a /etc/libvirt/qemu /usr/local/share/virt-reloaded/qemu-skel

RUN mkdir -p /root/.ssh
RUN printf 'Host *\n\tStrictHostKeyChecking no\n' >> /root/.ssh/config

COPY src/ /usr/local/lib/virt-reloaded/
COPY startapp.sh /usr/local/bin/startapp

# Checkouts on Windows hand us CRLF, which a Linux shebang line will not survive.
RUN sed -i 's/\r$//' /usr/local/bin/startapp /usr/local/lib/virt-reloaded/* \
 && chmod 755 /usr/local/bin/startapp /usr/local/lib/virt-reloaded/* \
 && ln -sf /usr/local/lib/virt-reloaded/virt-3d /usr/local/bin/virt-3d \
 && ln -sf /usr/local/lib/virt-reloaded/virt-3d-gui /usr/local/bin/virt-3d-gui \
 && ln -sf /usr/local/lib/virt-reloaded/virt-gpu-check /usr/local/bin/virt-gpu-check

EXPOSE 80

CMD ["/usr/local/bin/startapp"]
