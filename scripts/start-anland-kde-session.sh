#!/usr/bin/env bash
set -euo pipefail

socket="${ANLAND_SOCKET:-/run/display.sock}"
if [[ ! -S "$socket" ]]; then
  printf 'Anland display socket is not ready: %s. Open the container Anland display first.\n' "$socket" >&2
  exit 1
fi

export DESKTOP_SESSION=plasma
export ANLAND=1
export ANLAND_SOCKET="$socket"
export ANLAND_DRM_DEVICE="${ANLAND_DRM_DEVICE:-/dev/dri/renderD128}"
export ANLAND_SKIP_IMPLICIT_SYNC_WAIT="${ANLAND_SKIP_IMPLICIT_SYNC_WAIT:-1}"
export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-kgsl}"
export FD_FORCE_KGSL="${FD_FORCE_KGSL:-1}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"

if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
  exec /usr/bin/startplasma-wayland "$@"
fi
exec /usr/bin/dbus-run-session /usr/bin/startplasma-wayland "$@"
