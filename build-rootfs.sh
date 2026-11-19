#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILDER_SOURCE="$ROOT_DIR/source/droidspaces-rootfs-builder"
ARMADA_IMAGE="${ARMADA_IMAGE:-ghcr.io/armadaos-freedom/armadaos-freedom@sha256:26e4e9d4b76cb194c8852daada2d257ab7e20078611dd2a6bb2911fe4f6a6a46}"
ARMADA_IMAGE_SOURCE="${ARMADA_IMAGE_SOURCE:-$ARMADA_IMAGE}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
OUTPUT_FILE="${OUTPUT_FILE:-$OUTPUT_DIR/ArmadaOS-Freedom-Droidspaces-aarch64.tar.xz}"
ANLAND_REPOSITORY="${ANLAND_REPOSITORY:-Goldzxcbug/droidspaces-package}"
ANLAND_RELEASE_TAG="${ANLAND_RELEASE_TAG:-anland-kde-packages}"
ROOTFS_USERNAME="${ROOTFS_USERNAME:-z}"

[[ "$ARMADA_IMAGE" =~ ^ghcr\.io/armadaos-freedom/armadaos-freedom(@sha256:[0-9a-f]{64}|:[A-Za-z0-9._-]+)$ || "$ARMADA_IMAGE" == armadaos-freedom:flattened ]] || {
  printf 'ARMADA_IMAGE must be the ArmadaOS Freedom GHCR image or the workflow flattened image.\n' >&2
  exit 1
}
[[ "$ARMADA_IMAGE_SOURCE" =~ ^ghcr\.io/armadaos-freedom/armadaos-freedom(@sha256:[0-9a-f]{64}|:[A-Za-z0-9._-]+)$ ]] || {
  printf 'ARMADA_IMAGE_SOURCE must reference the ArmadaOS Freedom GHCR image.\n' >&2
  exit 1
}
[[ -x "$BUILDER_SOURCE/scripts/sync-tui.sh" ]] || {
  printf 'Droidspaces rootfs builder is missing at %s; check out the pinned builder repository there.\n' "$BUILDER_SOURCE" >&2
  exit 1
}

for tool in docker; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$tool" >&2
    exit 1
  }
done

docker info >/dev/null 2>&1 || {
  printf 'Docker daemon is unavailable. Start Docker or set DOCKER_HOST.\n' >&2
  exit 1
}
docker buildx version >/dev/null 2>&1 || {
  printf 'Docker Buildx is required.\n' >&2
  exit 1
}
builder_info="$(docker buildx inspect --bootstrap 2>&1)" || {
  printf 'Docker Buildx builder is not ready:\n%s\n' "$builder_info" >&2
  exit 1
}
grep -qF 'linux/arm64' <<< "$builder_info" || {
  printf 'The selected Buildx builder cannot execute linux/arm64 steps. Use an ARM64 host or enable QEMU/binfmt.\n' >&2
  exit 1
}

mkdir -p -- "$OUTPUT_DIR"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/armada-droidspaces.XXXXXXXX")"
local_image='armadaos-freedom:droidspaces-rootfs'
container_id=''
cleanup() {
  if [[ -n "$container_id" ]]; then docker rm -f "$container_id" >/dev/null 2>&1 || true; fi
  docker image rm "$local_image" >/dev/null 2>&1 || true
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

tui_dir="$tmp_dir/tui"
anland_context="$tmp_dir/anland-kde"
anland_metadata="$tmp_dir/anland-kde-build-info"
bash "$BUILDER_SOURCE/scripts/sync-tui.sh" --output "$tui_dir" --source github
tui_revision="$(awk -F= '$1 == "revision" {print substr($0, index($0, "=") + 1)}' "$tui_dir/Gold-bug-tui-manifest")"
[[ "$tui_revision" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'The downloaded Anland/TUI manifest has an invalid revision.\n' >&2
  exit 1
}
bash "$ROOT_DIR/prepare-anland-kde.sh" \
  "$tui_dir" "$anland_context" "$anland_metadata" \
  "$ANLAND_REPOSITORY" "$ANLAND_RELEASE_TAG"
anland_revision="$(awk -F= '$1 == "ANLAND_PACKAGE_REVISION" {print substr($0, index($0, "=") + 1)}' "$anland_metadata")"
anland_archive="$(awk -F= '$1 == "ANLAND_ARCHIVE" {print substr($0, index($0, "=") + 1)}' "$anland_metadata")"
anland_sha256="$(awk -F= '$1 == "ANLAND_ARCHIVE_SHA256" {print substr($0, index($0, "=") + 1)}' "$anland_metadata")"
[[ "$anland_revision" =~ ^[A-Za-z0-9._-]+$ && "$anland_archive" =~ ^anland-kde-fedora44-[A-Za-z0-9._-]+-aarch64\.tar\.gz$ && "$anland_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'The prepared Anland package metadata is invalid.\n' >&2
  exit 1
}

printf 'Building ARM64 ArmadaOS rootfs with Anland KDE revision %s\n' "$anland_revision"
secret_args=()
if [[ -n "${ROOTFS_PASSWORD:-}" ]]; then
  secret_args+=(--secret id=rootfs_password,env=ROOTFS_PASSWORD)
fi
docker buildx build \
  --platform linux/arm64 \
  --build-context "droidspaces-tui=$tui_dir" \
  --build-context "anland-kde=$anland_context" \
  --build-arg "ARMADA_IMAGE=$ARMADA_IMAGE" \
  --build-arg "DROIDSPACES_TUI_REVISION=$tui_revision" \
  --build-arg "ANLAND_REPOSITORY=$ANLAND_REPOSITORY" \
  --build-arg "ANLAND_RELEASE_TAG=$ANLAND_RELEASE_TAG" \
  --build-arg "ANLAND_PACKAGE_REVISION=$anland_revision" \
  --build-arg "ANLAND_ARCHIVE_NAME=$anland_archive" \
  --build-arg "ANLAND_ARCHIVE_SHA256=$anland_sha256" \
  --build-arg DESKTOP=kde \
  --build-arg DISPLAY_BACKEND=anland-wayland \
  --build-arg DESKTOP_AUTOSTART=false \
  --build-arg "USERNAME=$ROOTFS_USERNAME" \
  "${secret_args[@]}" \
  --file "$ROOT_DIR/Containerfile" \
  --target armada \
  --load \
  --tag "$local_image" \
  "$BUILDER_SOURCE"

container_id="$(docker create --platform linux/arm64 "$local_image" /bin/true)"
docker export --output "$tmp_dir/rootfs.tar" "$container_id"
docker rm "$container_id" >/dev/null
container_id=''
docker image rm "$local_image" >/dev/null

DROIDSPACES_TUI_REVISION="$tui_revision" \
ANLAND_REPOSITORY="$ANLAND_REPOSITORY" \
ANLAND_RELEASE_TAG="$ANLAND_RELEASE_TAG" \
ANLAND_PACKAGE_REVISION="$anland_revision" \
ANLAND_ARCHIVE_NAME="$anland_archive" \
ANLAND_ARCHIVE_SHA256="$anland_sha256" \
  "$ROOT_DIR/package-rootfs.sh" \
    "$tmp_dir/rootfs.tar" \
    "$OUTPUT_FILE" \
    "$ARMADA_IMAGE_SOURCE" \
    "$tui_revision"
printf 'Created %s\n' "$OUTPUT_FILE"
