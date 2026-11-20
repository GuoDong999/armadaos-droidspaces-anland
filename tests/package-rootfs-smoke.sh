#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/armada-rootfs-smoke.XXXXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

fixture="$tmp_dir/rootfs"
mkdir -p "$fixture/etc" "$fixture/usr/lib/systemd" "$fixture/usr/bin"
touch "$fixture/etc/os-release" "$fixture/usr/lib/systemd/systemd" "$fixture/usr/bin/bash"
tar --format=pax --owner=0 --group=0 --numeric-owner -cf "$tmp_dir/rootfs.tar" -C "$fixture" .

"$ROOT_DIR/package-rootfs.sh" \
  - \
  "$tmp_dir/ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz" \
  'ghcr.io/armadaos-freedom/armadaos-freedom@sha256:test' \
  < "$tmp_dir/rootfs.tar"

archive="$tmp_dir/ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz"
xz -t "$archive"
(cd "$tmp_dir" && sha256sum -c ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz.sha256)
tar -tJf "$archive" > "$tmp_dir/final-members"
read -r first_member < "$tmp_dir/final-members"
[[ "$first_member" == container.config ]]
tar -xOf "$archive" container.config > "$tmp_dir/config-extracted"
grep -Fxq 'net_mode=nat' "$tmp_dir/config-extracted"
grep -Fxq 'enable_x11=0' "$tmp_dir/config-extracted"
grep -Fxq 'enable_anland=1' "$tmp_dir/config-extracted"
grep -Fxq 'allow_sandboxing=1' "$tmp_dir/config-extracted"
grep -Fxq 'enable_gpu_mode=1' "$tmp_dir/config-extracted"
grep -Fxq 'ARMADA_IMAGE=ghcr.io/armadaos-freedom/armadaos-freedom@sha256:test' "$archive.source"
grep -Fxq 'ANLAND_RELEASE_TAG=anland-kde-packages' "$archive.source"

split -b 1024 -d -a 2 "$archive" "$archive.part-"
(cd "$tmp_dir" && sha256sum ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz.part-* \
    > ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz.parts.sha256)
"$ROOT_DIR/scripts/assemble-rootfs-release.sh" \
    "$tmp_dir" "$tmp_dir/reassembled.tar.xz"
cmp "$archive" "$tmp_dir/reassembled.tar.xz"
printf 'package smoke test passed\n'
