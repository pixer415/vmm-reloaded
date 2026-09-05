# Docker virt-manager reloaded
### GTK Broadway web UI for libvirt, with working guest 3D acceleration

![Docker virt-manager](docker-virt-manager.gif)

A fork of [m-bers/docker-virt-manager](https://github.com/m-bers/docker-virt-manager) that
borrows the GPU plumbing from [dockur/chromeos](https://github.com/dockur/chromeos) so that
virt-manager's **3D acceleration** and **OpenGL** options stop failing at boot.

---

## Why the original could not do it

The upstream image is only a *client*. It runs virt-manager over GTK Broadway and talks to a
libvirtd somewhere else - usually the host's, through a bind-mounted
`/var/run/libvirt/libvirt-sock`. Ticking "3D acceleration" in that setup asks the **host's**
QEMU for virgl. If that QEMU was built without the OpenGL modules, libvirt refuses the domain:

```
unsupported configuration: 3d acceleration is not supported by this QEMU binary
```

Nothing inside a client container can change that, which is why adding `/dev/dri` to the old
compose file on its own does nothing.

The chromeos container has no such problem because it *is* the hypervisor: it ships its own
QEMU with `qemu-system-modules-opengl`, its own Mesa/virglrenderer, and it gets `/dev/dri`
passed in. It then boots guests with

```
-device virtio-vga-gl -display egl-headless,rendernode=/dev/dri/renderD128 -vnc ...
```

This fork moves the same stack in here: the container now runs **libvirtd and QEMU itself**,
so the "3D acceleration" checkbox is backed by a QEMU that actually has the GL devices.

## What was added

| | |
|---|---|
| Ubuntu 24.04 base | the published `mber5/broadway-baseimage` is still Ubuntu 20.04 from January 2022, which has neither `qemu-system-modules-opengl` nor `swtpm`, and a QEMU (4.2) far too old for this. The Broadway glue is copied out of it and everything else is rebuilt on 24.04 |
| `qemu-system-modules-opengl` | supplies `virtio-vga-gl`, `virtio-gpu-gl` and `ui-egl-headless.so` - the exact things libvirt probes for before it accepts `<acceleration accel3d='yes'/>` |
| `qemu-system-modules-spice` | SPICE with GL, for the "OpenGL" checkbox |
| `libvirglrenderer1`, Mesa EGL/GBM/DRI | host-side renderer; without it QEMU has the `-gl` devices but dies with `egl: render node init failed` |
| `libvirt-daemon-system` + `qemu-system-x86` | the in-container hypervisor |
| [`src/gpu.sh`](src/gpu.sh) | picks a usable DRM render node the way `qemus/qemu`'s `display.sh` does, and recreates missing `/dev/dri` nodes |
| [`src/libvirt.sh`](src/libvirt.sh) | starts `virtlogd` + `libvirtd` and writes a container-appropriate `qemu.conf`, including the render node in `cgroup_device_acl` |
| [`src/virt-3d`](src/virt-3d) | one command to wire acceleration into a domain correctly |
| [`src/virt-gpu-check`](src/virt-gpu-check) | tells you which layer is missing when a guest still will not boot |

Ports and Docker networking are unchanged from upstream: still `8185:80`, still bridge.

## Usage

```bash
cd docker-virt-reloaded
docker compose up -d --build
```

Then open <http://localhost:8185>.

The image is built locally rather than pulled - the acceleration lives in this repo's
Dockerfile, not in the published `mber5/virt-manager` image.

### Requirements

- A Linux host with KVM (`/dev/kvm`) and a DRM render node (`/dev/dri/renderD128`).
- An Intel or AMD GPU. NVIDIA needs the container toolkit and the proprietary driver's EGL.
- Docker Desktop on Windows 11 works for KVM via WSL2, but WSL's `/dev/dri` is a d3d12
  virtual device; treat 3D there as best-effort.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `LIBVIRTD` | `Y` | Run libvirtd inside the container. `N` restores upstream client-only behaviour. |
| `GPU` | `Y` | Look for a DRM render node at startup. |
| `RENDERNODE` | *(empty)* | Pin a node, e.g. `/dev/dri/renderD129`. Empty autodetects. |
| `LIBVIRT_NETWORK` | `Y` | Try to start libvirt's `default` NAT network. |
| `HOSTS` | `['qemu:///system']` | Same as upstream. Left empty with `LIBVIRTD=Y`, it defaults to the local daemon. |
| `DARK_MODE` | `false` | Same as upstream. |

## Turning acceleration on for a guest

### The catch with the OpenGL checkbox

virt-manager only offers the **OpenGL** checkbox for SPICE displays, and that path uses
SPICE's *local* handoff: QEMU passes the rendered frame to the client as a dmabuf file
descriptor, which the client has to import through EGL on the same machine. That is also why
checking it forces **Listen type: None**.

The Broadway viewer cannot import a dmabuf - there is no GL context in a browser-rendered GTK
window. So SPICE + OpenGL will start the guest without complaint on this image, but the
console stays black.

### What to do instead

Use the same combination the chromeos container uses: keep an ordinary VNC or SPICE display
for viewing, and let a separate `egl-headless` device do the GPU rendering. QEMU renders the
guest on the real GPU and copies the result into the display's framebuffer, so it streams to
any client - including the one embedded in virt-manager.

The display path is then **identical to a guest with no acceleration at all**: ordinary pixels
in a VNC framebuffer, drawn by gtk-vnc through Cairo, shipped to the browser by Broadway. The
GPU only changes what QEMU does *before* the framebuffer is filled. Nothing about viewing
changes, which is exactly why this arrangement works here and SPICE's `gl=on` does not.

From the terminal icon at the bottom left of the web UI:

```bash
virt-3d enable my-vm
```

That edits the domain to:

```xml
<video>
  <model type='virtio' heads='1' primary='yes'>
    <acceleration accel3d='yes'/>
  </model>
</video>
<graphics type='vnc' autoport='yes'>
  <listen type='address' address='127.0.0.1'/>
</graphics>
<graphics type='egl-headless'>
  <gl rendernode='/dev/dri/renderD128'/>
</graphics>
```

It also undoes a SPICE `gl=on` / `listen=none` pair if you already ticked the checkbox, since
`egl-headless` now does that job. Restart the guest afterwards.

Other subcommands:

```bash
virt-3d list             # every domain and its acceleration state
virt-3d status my-vm
virt-3d disable my-vm
```

You can do the same by hand in **Edit → Preferences → Enable XML editing** (already on) via
the XML tab of the Display device.

### Doing it through the GUI

If you would rather stay in the UI: set the **Video** device model to `virtio` and tick
**3D acceleration**, then add the `egl-headless` graphics device from the XML editor. The
Display page's warning rows tell you what is still missing - virt-manager greys nothing out
here, it just lets libvirt reject the domain at boot.

## Troubleshooting

Run `virt-gpu-check` from the web UI's terminal first; it walks the whole chain.

| Error at boot | Cause |
|---|---|
| `3d acceleration is not supported by this QEMU binary` | `qemu-system-modules-opengl` missing, or you are pointed at a host libvirtd that lacks it (`LIBVIRTD=N`) |
| `egl-headless display is not supported with this QEMU binary` | same package |
| `egl: render node init failed` / `Failed to initialize EGL` | `/dev/dri` not passed in, or Mesa's EGL/GBM missing |
| `Could not open '/dev/dri/renderD128': Permission denied` | the node is not in `cgroup_device_acl` in `/etc/libvirt/qemu.conf` |
| `Unable to create cgroup` | `cgroup_controllers = []` was not applied - check the managed block at the end of `qemu.conf` |
| Guest boots, console is black | SPICE `gl=on` with the Broadway viewer. Use `virt-3d enable` instead. |
| Guest has no network | libvirt's default NAT network needs `cap_add: NET_ADMIN` and `/dev/net/tun`; both are commented out in the compose file |

The render node dropdown on the Display page stays empty unless the host's udev database is
visible. Mount `/run/udev:/run/udev:ro` to populate it - autodetection does not need it.

### Going back to a host libvirtd

Set `LIBVIRTD: "N"` and uncomment the `libvirt-sock` bind mount. The container then behaves
exactly like upstream, and the 3D checkboxes depend on the host's QEMU rather than this
image's.

## Packaging it as a ZimaOS app

[`zimaos/`](zimaos) holds a v2 app-store repository for own-hypervisor mode:

```
zimaos/
├── store-config.json
├── supported-languages.json
└── Apps/VirtManagerReloaded/
    ├── docker-compose.yml
    └── icon.svg
```

Three things to do before it will install:

1. **Replace the `OWNER` placeholders** - 15 of them, across the app id, image, icon URL and
   repo links.
2. **Publish the image.** ZimaOS installs from a registry and cannot build from source:
   `docker build -t ghcr.io/OWNER/virt-manager-reloaded:1.0.0 . && docker push ...`
3. **Add `thumbnail.png` and `screenshot-1.png`** next to `icon.svg`.

Host the repo over HTTPS, then add it in ZimaOS under **App Store → Add Source**.

The app compose uses bind mounts under `/DATA/AppData` rather than the named volume the
development compose uses, because that is the ZimaOS convention. Docker does not seed a bind
mount from the image, so `libvirt_seed_config` in [src/libvirt.sh](src/libvirt.sh) restores
the default network and anything else missing on startup, without clobbering what is there.

### ZimaOS already runs libvirt

ZimaOS's own ZVM feature is libvirt-based, so the box has a libvirtd of its own. This app
deliberately does **not** use it - it runs its own daemon with its own GPU-capable QEMU, which
is the only way to get guest 3D on a system whose host QEMU may lack the modules. The cost is
that the two do not see each other's VMs.

If ZimaOS's host QEMU turns out to have the GL modules, client mode is the lighter option -
set `LIBVIRTD: "N"`, mount the host socket, and the app manages the same VMs as the built-in
page. Check with:

```bash
qemu-system-x86_64 -device help | grep virtio-vga-gl
```

## Credits

- [m-bers/docker-virt-manager](https://github.com/m-bers/docker-virt-manager) - the Broadway
  virt-manager container this forks.
- [dockur/chromeos](https://github.com/dockur/chromeos) and
  [qemus/qemu](https://github.com/qemus/qemu) - the render node detection and the
  `egl-headless` + `virtio-vga-gl` arrangement.
