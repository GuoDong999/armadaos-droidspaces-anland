#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  printf 'Usage: %s ROOTFS_TAR OUTPUT_TAR_XZ [IMAGE_REFERENCE] [TUI_REVISION]\n' "$0" >&2
  exit 2
fi

input_tar="$1"
output_file="$2"
image_reference="${3:-unknown}"
tui_revision="${4:-unknown}"
anland_repository="${ANLAND_REPOSITORY:-Goldzxcbug/droidspaces-package}"
anland_release_tag="${ANLAND_RELEASE_TAG:-anland-kde-packages}"
anland_package_revision="${ANLAND_PACKAGE_REVISION:-unknown}"
anland_archive_name="${ANLAND_ARCHIVE_NAME:-unknown}"
anland_archive_sha256="${ANLAND_ARCHIVE_SHA256:-unknown}"
[[ "$anland_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  printf 'Invalid Anland repository reference.\n' >&2
  exit 1
}
[[ "$anland_release_tag" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Invalid Anland release tag.\n' >&2
  exit 1
}
[[ "$anland_package_revision" == unknown || "$anland_package_revision" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Invalid Anland package revision.\n' >&2
  exit 1
}
[[ "$anland_archive_name" == unknown || "$anland_archive_name" =~ ^anland-kde-fedora44-[A-Za-z0-9._-]+-aarch64\.tar\.gz$ ]] || {
  printf 'Invalid Anland archive name.\n' >&2
  exit 1
}
[[ "$anland_archive_sha256" == unknown || "$anland_archive_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'Invalid Anland archive SHA-256.\n' >&2
  exit 1
}
if [[ ( "$anland_archive_name" == unknown && "$anland_archive_sha256" != unknown ) || \
      ( "$anland_archive_name" != unknown && "$anland_archive_sha256" == unknown ) ]]; then
  printf 'Anland archive name and SHA-256 must be supplied together.\n' >&2
  exit 1
fi
[[ "$tui_revision" == unknown || "$tui_revision" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'Invalid Droidspaces TUI revision.\n' >&2
  exit 1
}
[[ "$input_tar" == - || -f "$input_tar" ]] || { printf 'Rootfs tar not found: %s\n' "$input_tar" >&2; exit 1; }

for tool in tar xz sha256sum dd grep; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$tool" >&2
    exit 1
  }
done

mkdir -p -- "$(dirname -- "$output_file")"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/armada-rootfs-package.XXXXXXXX")"
pending_output="$(mktemp "${output_file}.tmp.XXXXXXXX")"
cleanup() {
  rm -rf -- "$tmp_dir"
  [[ -z "$pending_output" ]] || rm -f -- "$pending_output"
}
trap cleanup EXIT

cat > "$tmp_dir/container.config" <<'EOF'
# Droidspaces defaults for ArmadaOS Freedom ARM64
net_mode=nat
enable_x11=0
enable_anland=1
allow_sandboxing=1
enable_gpu_mode=1
EOF

tar --format=ustar --owner=0 --group=0 --numeric-owner \
  -cf "$tmp_dir/config.tar" -C "$tmp_dir" container.config
config_size="$(wc -c < "$tmp_dir/container.config")"
config_blocks=$((1 + (config_size + 511) / 512))
if [[ "$input_tar" == - ]]; then
  { dd if="$tmp_dir/config.tar" bs=512 count="$config_blocks" status=none; cat; } | xz -T0 -6 -c > "$pending_output"
else
  { dd if="$tmp_dir/config.tar" bs=512 count="$config_blocks" status=none; cat "$input_tar"; } | xz -T0 -6 -c > "$pending_output"
fi
xz -t "$pending_output"
tar -tJf "$pending_output" > "$tmp_dir/final-members"
read -r first_member < "$tmp_dir/final-members"
if [[ "$first_member" != container.config ]]; then
  printf 'container.config is not the first rootfs archive entry.\n' >&2
  exit 1
fi
for member in etc/os-release usr/lib/systemd/systemd usr/bin/bash; do
  if ! grep -Eq "(^|/)${member}$" "$tmp_dir/final-members"; then
    printf 'Exported rootfs is missing required path: %s\n' "$member" >&2
    exit 1
  fi
done

mv -f -- "$pending_output" "$output_file"
pending_output=""
(cd -- "$(dirname -- "$output_file")" && sha256sum "$(basename -- "$output_file")" > "$(basename -- "$output_file").sha256")
{
  printf 'ARMADA_IMAGE=%s\n' "$image_reference"
  printf 'DROIDSPACES_TUI_REVISION=%s\n' "$tui_revision"
  printf 'ANLAND_REPOSITORY=%s\n' "$anland_repository"
  printf 'ANLAND_RELEASE_TAG=%s\n' "$anland_release_tag"
  printf 'ANLAND_PACKAGE_REVISION=%s\n' "$anland_package_revision"
  printf 'ANLAND_ARCHIVE=%s\n' "$anland_archive_name"
  printf 'ANLAND_ARCHIVE_SHA256=%s\n' "$anland_archive_sha256"
} > "$output_file.source"
printf 'Created %s\n' "$output_file"
