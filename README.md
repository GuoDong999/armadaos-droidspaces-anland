# ArmadaOS Freedom for Droidspaces

[English](README.md) | [简体中文](README.zh-CN.md)

This project exports an ARM64 root filesystem from ArmadaOS Freedom's Fedora 44 image, replaces its KWin/Xwayland with the Fedora 44 ARM64 Anland-patched packages, and adds Droidspaces container configuration. It does not make a bootable Android/Linux image.

Droidspaces uses the Android host kernel. ArmadaOS's device kernel, device tree, boot payloads, and direct hardware control do not run inside the container. Anland needs a compatible GPU render node and the Android Anland app; those depend on the target device and Droidspaces kernel.

## Build

Requirements: Docker Engine with a working daemon, Docker Buildx on a builder that supports ARM64 execution (native ARM64 or QEMU/binfmt), `curl`, `tar`, and `xz`. The default input is pinned to the verified ArmadaOS Freedom Fedora 44 ARM64 image digest (`sha256:26e4e9d4b76cb194c8852daada2d257ab7e20078611dd2a6bb2911fe4f6a6a46`). The Anland KDE archive is selected from its release manifest and verified against its SHA-256 before the build.

```bash
./build-rootfs.sh
```

To choose another published image or output location:

```bash
ARMADA_IMAGE=ghcr.io/armadaos-freedom/armadaos-freedom:stable \
OUTPUT_FILE="$PWD/dist/armada-freedom.tar.xz" \
./build-rootfs.sh
```

The packager puts Droidspaces' `container.config` first in the `.tar.xz`, validates required rootfs paths, tests the XZ stream, and writes a SHA-256 sidecar plus source provenance. Import the archive in Droidspaces from the RootFS management screen. The provenance records the Armada image digest, TUI revision, Anland package revision, archive name, and archive SHA-256. The offline packaging smoke test is `tests/package-rootfs-smoke.sh`; it uses a synthetic rootfs fixture and does not test the Armada image runtime.

## Build with GitHub Actions

The `.github/workflows/build-rootfs.yml` workflow is manually triggered from the repository's Actions tab. It uses a native ARM64 runner, checks for 40 GB free space, flattens ArmadaOS's OCI layers before the Docker build, and uploads the rootfs, SHA-256, and provenance as an artifact retained for one day. The workflow defaults to the restored upstream `armada` account, whose password is locked; it does not use the previously supplied local password.

## Release Download

Release `v0.1.0-anland.1` is the earlier build with username `z`. The restored-account build will use `armada` and a new release tag. The repository is now public, so its releases and assets are publicly accessible.

Because GitHub limits an individual Release asset to less than 2 GiB, the rootfs is published as multiple `.part-*` files. Download every rootfs part, both SHA-256 manifests, the `.source` provenance, and `assemble-rootfs-release.sh` into one directory. Reassemble and verify the parts with:

```bash
chmod +x assemble-rootfs-release.sh
./assemble-rootfs-release.sh . ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz
```

The script verifies each part, joins them in order, and verifies the complete rootfs SHA-256 before creating the `.tar.xz`.

## Defaults and First Start

The generated configuration selects NAT, enables Anland Display and GPU Access, disables Termux:X11, and allows user namespaces for Plasma. The latter weakens container isolation; use this image only if you trust its root user.

The restored rootfs account is the upstream `armada` user. Its password is locked. On first start, enter as root and run `passwd armada` to set a password. SDDM is masked because the Android host owns display startup; the systemd default target is `multi-user.target`.

On Android, install the Droidspaces-supported Anland 5.x APK, grant it root access, and complete Anland's one-time host setup. In the container settings leave GPU Access and Anland Display on and Termux:X11 off. Start the container, open its Anland launch action, then run `start-desktop-session` as `armada` in the container terminal to launch `startplasma-wayland`.

## Known Limits

- This is a derived container rootfs, not an official ArmadaOS release or a supported ArmadaOS installation target.
- Anland requires the patched Fedora 44 KWin/Xwayland packages, which replace Armada Freedom's customized KWin packages. Freedom-specific KWin behavior may not carry over.
- ArmadaOS's boot/update/install utilities and hardware-control services are not validated for use in a container. Do not use them to update or modify the Android host.
- The default base image is pinned by digest. If `ARMADA_IMAGE` is overridden with a tag such as `testing` or `stable`, that tag can move; use an image digest for repeatable builds.
- The Anland RPM source is a rolling release tag; each build records its manifest revision and archive hash in the output provenance.
- Anland GPU rendering still requires validation on the target device.

## Sources

- ArmadaOS Freedom: https://github.com/ArmadaOS-Freedom/armadaos-freedom
- Droidspaces runtime: https://github.com/ravindu644/Droidspaces-OSS
- Droidspaces rootfs builder and Anland packages: https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder and https://github.com/Goldzxcbug/droidspaces-package

The upstream repositories retain their own licenses. This adapter is a build wrapper and configuration layer; it does not redistribute upstream source.
