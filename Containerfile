ARG ARMADA_IMAGE=ghcr.io/armadaos-freedom/armadaos-freedom@sha256:26e4e9d4b76cb194c8852daada2d257ab7e20078611dd2a6bb2911fe4f6a6a46
FROM ${ARMADA_IMAGE} AS armada

ARG DESKTOP=kde
ARG DISPLAY_BACKEND=anland-wayland
ARG DESKTOP_AUTOSTART=false
ARG USERNAME=z
ARG DROIDSPACES_TUI_REVISION=unknown
ARG ANLAND_REPOSITORY=Goldzxcbug/droidspaces-package
ARG ANLAND_RELEASE_TAG=anland-kde-packages
ARG ANLAND_PACKAGE_REVISION=unknown
ARG ANLAND_ARCHIVE_NAME=unknown
ARG ANLAND_ARCHIVE_SHA256=unknown

USER 0
RUN <<'EOF_RUN'
set -euxo pipefail

dnf5 -y install dhcp-client
dnf5 clean all

for group in aid_inet:3003 aid_net_raw:3004 aid_net_admin:3005; do
    name=${group%%:*}
    gid=${group##*:}
    if ! getent group "$name" >/dev/null; then
        existing=$(getent group "$gid" | cut -d: -f1 || true)
        if [ -n "$existing" ]; then
            echo "GID $gid is already assigned to $existing" >&2
            exit 1
        fi
        groupadd -g "$gid" "$name"
    fi
done

if ! getent group droidspaces-gpu >/dev/null; then
    existing=$(getent group 786 | cut -d: -f1 || true)
    if [ -n "$existing" ]; then
        echo "GID 786 is already assigned to $existing" >&2
        exit 1
    fi
    groupadd -r -g 786 droidspaces-gpu
fi

for group in input video tty wheel audio render; do
    getent group "$group" >/dev/null && usermod -aG "$group" root || true
    getent group "$group" >/dev/null && usermod -aG "$group" "$USERNAME" || true
done
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$USERNAME"
    for group in input video tty wheel audio render; do
        getent group "$group" >/dev/null && usermod -aG "$group" "$USERNAME" || true
    done
fi
usermod -aG aid_inet,aid_net_raw,aid_net_admin,droidspaces-gpu root
usermod -aG aid_inet,aid_net_raw,aid_net_admin,droidspaces-gpu "$USERNAME"
passwd -l armada
sed -i 's/^hosts:.*/hosts: files dns myhostname/' /etc/nsswitch.conf

mkdir -p \
    /etc/systemd/system/multi-user.target.wants \
    /etc/systemd/journald.conf.d \
    /etc/systemd/logind.conf.d
ln -sfn /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sfn /dev/null /etc/systemd/system/systemd-journald-audit.socket
ln -sfn /dev/null /etc/systemd/system/sddm.service
ln -sfn /dev/null /etc/systemd/system/NetworkManager.service
ln -sfn /dev/null /etc/systemd/system/systemd-networkd.service
ln -sfn /dev/null /etc/systemd/system/systemd-resolved.service
ln -sfn /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target

cat > /etc/systemd/journald.conf.d/50-droidspaces.conf <<'EOF'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOF

cat > /etc/systemd/logind.conf.d/50-droidspaces.conf <<'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# Do not let the container's udev daemon inspect Android devices unless enabled.
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    cat > "/etc/systemd/system/${unit}.d/50-droidspaces.conf" <<'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q 'enable_hw_access=1' /run/droidspaces/container.config"
EOF
done

cat > /etc/systemd/system/ds-dhcp.service <<'EOF'
[Unit]
Description=Droidspaces NAT DHCP (Root Bypass)
After=network.target

[Service]
Type=forking
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
ExecStart=/usr/sbin/dhclient
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
ln -sfn /etc/systemd/system/ds-dhcp.service /etc/systemd/system/multi-user.target.wants/ds-dhcp.service

rm -rf /var/cache/dnf /var/cache/libdnf5 /var/log/journal/*
EOF_RUN

RUN --mount=type=secret,id=rootfs_password,target=/run/secrets/rootfs_password,required=false \
    <<'EOF_PASSWORD'
set -euo pipefail
passwd -l "$USERNAME"
if [[ -s /run/secrets/rootfs_password ]]; then
    password="$(cat /run/secrets/rootfs_password)"
    [[ "$password" != *$'\n'* ]]
    printf '%s:%s\n' "$USERNAME" "$password" | chpasswd
    unset password
fi
EOF_PASSWORD

RUN --mount=type=bind,source=scripts,target=/run/droidspaces-scripts \
    --mount=type=bind,from=droidspaces-tui,target=/run/droidspaces-tui \
    bash -euo pipefail -c '\
      staging=/tmp/droidspaces-rootfs-tools; \
      mkdir -p "$staging/etc"; \
      cp /etc/os-release "$staging/etc/os-release"; \
      sed -i -E "s/^ID=\\\"?armada\\\"?$/ID=fedora/" "$staging/etc/os-release"; \
      DESKTOP="$DESKTOP" DISPLAY_BACKEND="$DISPLAY_BACKEND" \
        bash /run/droidspaces-scripts/install-rootfs-tools.sh \
          --root "$staging" --tui-dir /run/droidspaces-tui \
          --desktop "$DESKTOP" --display-backend "$DISPLAY_BACKEND"; \
      cp -a "$staging"/. /; \
      rm -rf "$staging"'

RUN --mount=type=bind,from=anland-kde,target=/run/anland-kde,ro \
    cp -a /run/anland-kde/. /tmp/anland-kde.ArmadaDroidspaces && \
    ANLAND_KDE_RELEASE_REPOSITORY="$ANLAND_REPOSITORY" \
    ANLAND_KDE_RELEASE_TAG="$ANLAND_RELEASE_TAG" \
    ANLAND_KDE_WORK_DIR=/tmp/anland-kde.ArmadaDroidspaces \
    ANLAND_KDE_PACKAGE_DIR=/tmp/anland-kde.ArmadaDroidspaces/anland-kde-packages/fedora44 \
    ANLAND_KDE_ARCHIVE_NAME="$ANLAND_ARCHIVE_NAME" \
    /usr/local/sbin/install-anland-desktop kde --1 && \
    rm -rf /tmp/anland-kde.ArmadaDroidspaces && \
    /usr/local/sbin/configure-desktop "$DESKTOP" "$DISPLAY_BACKEND" "$DESKTOP_AUTOSTART" "$USERNAME" && \
    mkdir -p /usr/share/armada && \
    printf 'DROIDSPACES_TUI_REVISION=%s\nANLAND_REPOSITORY=%s\nANLAND_RELEASE_TAG=%s\nANLAND_PACKAGE_REVISION=%s\nANLAND_ARCHIVE_NAME=%s\nANLAND_ARCHIVE_SHA256=%s\n' \
      "$DROIDSPACES_TUI_REVISION" "$ANLAND_REPOSITORY" "$ANLAND_RELEASE_TAG" \
      "$ANLAND_PACKAGE_REVISION" "$ANLAND_ARCHIVE_NAME" "$ANLAND_ARCHIVE_SHA256" \
      > /usr/share/armada/droidspaces-rootfs-build-info

RUN rm -f \
      /usr/local/sbin/configure-chrome \
      /usr/local/sbin/configure-desktop \
      /usr/local/sbin/install-desktop \
      /usr/local/sbin/install-fcitx5 \
      /usr/local/sbin/install-anland-desktop \
      /usr/local/sbin/systemd257 \
      /usr/local/sbin/nosnap && \
    rm -rf /usr/local/lib/droidspaces/desktops /var/cache/dnf /var/cache/libdnf5

FROM scratch AS export
COPY --from=armada / /
