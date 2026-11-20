#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s RELEASE_ASSET_DIR OUTPUT_TAR_XZ\n' "$0" >&2
  exit 2
fi

asset_dir="$1"
output="$2"
name='ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz'
parts_manifest="$asset_dir/$name.parts.sha256"
rootfs_checksum="$asset_dir/$name.sha256"
[[ -d "$asset_dir" && -f "$parts_manifest" && -f "$rootfs_checksum" ]] || {
  printf 'Release parts or checksum manifests are missing.\n' >&2
  exit 1
}

mapfile -t parts < <(awk '{print $2}' "$parts_manifest")
((${#parts[@]} > 0)) || { printf 'No rootfs parts listed.\n' >&2; exit 1; }
for part in "${parts[@]}"; do
  [[ "$part" =~ ^${name//./\\.}\.part-[0-9]{2}$ && -f "$asset_dir/$part" ]] || {
    printf 'Invalid or missing rootfs part: %s\n' "$part" >&2
    exit 1
  }
done

mkdir -p -- "$(dirname -- "$output")"
temporary="$output.tmp.$$"
trap 'rm -f -- "$temporary"' EXIT
(
  cd -- "$asset_dir"
  sha256sum -c "$name.parts.sha256"
  cat -- "${parts[@]}" > "$temporary"
  expected="$(awk 'NR == 1 {print $1}' "$name.sha256")"
  actual="$(sha256sum "$temporary" | awk '{print $1}')"
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] || {
    printf 'Reassembled rootfs SHA-256 does not match.\n' >&2
    exit 1
  }
)
mv -f -- "$temporary" "$output"
trap - EXIT
printf 'Reassembled and verified %s\n' "$output"
