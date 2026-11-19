#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  printf 'Usage: %s TUI_DIR OUTPUT_CONTEXT METADATA_FILE REPOSITORY RELEASE_TAG\n' "$0" >&2
  exit 2
fi

tui_dir="$1"
output_context="$2"
metadata_file="$3"
repository="$4"
release_tag="$5"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  printf 'Invalid Anland repository.\n' >&2
  exit 1
}
[[ "$release_tag" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Invalid Anland release tag.\n' >&2
  exit 1
}
[[ -d "$tui_dir" && -x "$tui_dir/install-anland-kde.sh" ]] || {
  printf 'Verified Anland KDE installer is missing.\n' >&2
  exit 1
}

for tool in curl awk sha256sum tar; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$tool" >&2
    exit 1
  }
done

mkdir -p -- "$output_context" "$(dirname -- "$metadata_file")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/armada-anland-fetch.XXXXXXXX")"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT
manifest="$work_dir/anland-kde-manifest"
archive="$work_dir/anland-kde.tar.gz"
base_url="https://github.com/$repository/releases/download/$release_tag"
curl --http1.1 -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
  "$base_url/anland-kde-manifest" -o "$manifest"

manifest_value() {
  awk -F= -v key="$1" '
    $1 == key { count++; value = substr($0, index($0, "=") + 1) }
    END { if (count != 1) exit 1; print value }
  ' "$manifest"
}

format="$(manifest_value format)"
manifest_tag="$(manifest_value release_tag)"
revision="$(manifest_value revision)"
archive_name="$(manifest_value fedora44)"
archive_sha256="$(manifest_value fedora44_sha256)"
[[ "$format" == 1 && "$manifest_tag" == "$release_tag" ]] || {
  printf 'Anland release manifest metadata is invalid.\n' >&2
  exit 1
}
[[ "$revision" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'Anland release revision is invalid.\n' >&2
  exit 1
}
[[ "$archive_name" =~ ^anland-kde-fedora44-[A-Za-z0-9._-]+-aarch64\.tar\.gz$ && "$archive_name" != *..* ]] || {
  printf 'Anland archive name is invalid for Fedora 44 ARM64.\n' >&2
  exit 1
}
[[ "$archive_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || {
  printf 'Anland archive SHA-256 is invalid.\n' >&2
  exit 1
}
curl --http1.1 -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
  "$base_url/$archive_name" -o "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c -

ANLAND_KDE_RELEASE_REPOSITORY="$repository" ANLAND_KDE_RELEASE_TAG="$release_tag" \
  source "$tui_dir/install-anland-kde.sh"
ARCHIVE_TARGET=fedora44
TARGET='Fedora 44'
validate_archive_contents "$archive"
tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$output_context"
package_dir="$output_context/anland-kde-packages/fedora44"
[[ -d "$package_dir" ]] || {
  printf 'Verified archive did not contain the Fedora 44 package directory.\n' >&2
  exit 1
}
shopt -s nullglob
rpms=("$package_dir"/*.rpm)
shopt -u nullglob
((${#rpms[@]} > 0)) || {
  printf 'Verified Fedora 44 Anland archive contains no RPM packages.\n' >&2
  exit 1
}
printf 'ANLAND_REPOSITORY=%s\nANLAND_RELEASE_TAG=%s\nANLAND_PACKAGE_REVISION=%s\nANLAND_ARCHIVE=%s\nANLAND_ARCHIVE_SHA256=%s\n' \
  "$repository" "$release_tag" "$revision" "$archive_name" "${archive_sha256,,}" \
  > "$metadata_file"
printf 'Prepared %d verified Anland RPMs at revision %s\n' "${#rpms[@]}" "$revision"
