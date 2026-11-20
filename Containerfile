ARG ARMADA_IMAGE=ghcr.io/armadaos-freedom/armadaos-freedom@sha256:26e4e9d4b76cb194c8852daada2d257ab7e20078611dd2a6bb2911fe4f6a6a46
FROM ${ARMADA_IMAGE} AS armada

ARG DESKTOP=kde
ARG DISPLAY_BACKEND=anland-wayland
ARG DESKTOP_AUTOSTART=false
ARG USERNAME=armada
ARG DROIDSPACES_TUI_REVISION=unknown
ARG ANLAND_REPOSITORY=Goldzxcbug/droidspaces-package
ARG ANLAND_RELEASE_TAG=anland-kde-packages
ARG ANLAND_PACKAGE_REVISION=unknown
ARG ANLAND_ARCHIVE_NAME=unknown
ARG ANLAND_ARCHIVE_SHA256=unknown

USER 0
RUN <<'EOF_RUN'
set -euxo pipefail

dnf5 -y install --setopt=install_weak_deps=False dhcp-client dbus-daemon binutils
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
# Match the reference Armada container's graphical/input/audio groups.
getent group pipewire >/dev/null || groupadd -r pipewire
getent group gamemode >/dev/null || groupadd -r gamemode
input_device_group="$(getent group 1004 | cut -d: -f1 || true)"
if [ -z "$input_device_group" ]; then groupadd -g 1004 -r armada-input; input_device_group=armada-input; fi
for group in pipewire gamemode seat "$input_device_group"; do
    getent group "$group" >/dev/null && usermod -aG "$group" "$USERNAME" || true
done
id "$USERNAME" >/dev/null 2>&1 || { echo "Missing upstream ArmadaOS account: $USERNAME" >&2; exit 1; }
usermod -aG aid_inet,aid_net_raw,aid_net_admin,droidspaces-gpu root
usermod -aG aid_inet,aid_net_raw,aid_net_admin,droidspaces-gpu "$USERNAME"
passwd -l "$USERNAME"
# Droidspaces supplies the Android host kernel, not an OSTree deployment.
rm -rf /sysroot /ostree /boot/efi /boot/loader* /boot/grub2 /boot/ostree /run/ostree-booted
for unit in \
    armada-bootimg-sync.service armada-esp-rename.service armada-boot-hotkeys.service \
    armada-installer-visibility.service armada-update-reserve.service armada-fixups.service \
    armada-device-quirks.service armada-input-calibration.service armada-controller-type.service \
    armada-rgb.service armada-rgb-brightness-watch.service armada-rgb-brightness-watch.path \
    armada-splash-early.service armada-splash-stall.service armada-splash-reboot-screen.service \
    armada-splash-poweroff-screen.service usr-share-guestos-android.mount armada-waydroid-input.service \
    waydroid-container.service jupiter-biosupdate armada-steam-default-session.service \
    armada-steamapps.service armada-flatpak-setup.service armada-mtp.service inputplumber.service \
    armada-powerd.service steamos-manager-session-cleanup.service armada-steam-charging-eta.service \
    bootc-generic-growpart.service var-lib-nfs-rpc_pipefs.mount chronyd.service \
    bootc-fetch-apply-updates.timer bootloader-update.service irqbalance.service \
    systemd-backlight@.service systemd-hibernate.service systemd-hybrid-sleep.service \
    systemd-suspend-then-hibernate.service flatpak-add-fedora-repos.service \
    armada-save-devcoredump@.service armada-guestos.service bluetooth.service; do
    ln -sf /dev/null "/etc/systemd/system/$unit"
done
mkdir -p /etc/systemd/user
for unit in steamos-manager-configure-cecd.service armada-steam-default-session.service armada-steam-charging-eta.service; do
    ln -sf /dev/null "/etc/systemd/user/$unit"
done
sed -i 's/^hosts:.*/hosts: files dns myhostname/' /etc/nsswitch.conf

mkdir -p \
    /etc/systemd/system/multi-user.target.wants \
    /etc/systemd/journald.conf.d \
    /etc/systemd/logind.conf.d
ln -sfn /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sfn /dev/null /etc/systemd/system/systemd-journald-audit.socket
# ArmadaOS's supported graphics path is SDDM -> Armada session, not a bare
# interactive startplasma-wayland. Container-specific setup follows below.
ln -sfn /dev/null /etc/systemd/system/NetworkManager.service
ln -sfn /dev/null /etc/systemd/system/systemd-networkd.service
ln -sfn /dev/null /etc/systemd/system/systemd-resolved.service
# graphical.target is selected below after the Armada session units are installed.

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

COPY --from=armada-adapter --chmod=0755 /scripts/start-anland-kde-session.sh /usr/local/bin/start-desktop-session
COPY --from=armada-adapter /scripts/patch-armada-plasma-session.py /tmp/patch-armada-plasma-session.py
COPY --from=armada-adapter /scripts/patch-armada-gamescope-startup.py /tmp/patch-armada-gamescope-startup.py
COPY --from=armada-adapter /scripts/patch-armada-container-desktop-mode.py /tmp/patch-armada-container-desktop-mode.py
COPY --from=armada-adapter --chmod=0755 /scripts/armada-container-session-control /usr/libexec/armada/session-control
COPY --from=armada-adapter --chmod=0755 /scripts/armada-gamescope-startup.sh /usr/libexec/armada/gamescope-startup-wait
COPY --from=armada-adapter --chmod=0755 /scripts/armada-steam-anland.sh /usr/libexec/armada/steam-anland-env

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
    printf 'DROIDSPACES_TUI_REVISION=%s\nANLAND_REPOSITORY=%s\nANLAND_RELEASE_TAG=%s\nANLAND_PACKAGE_REVISION=%s\nANLAND_ARCHIVE_NAME=%s\nANLAND_ARCHIVE_SHA256=%s\nROOTFS_USERNAME=%s\n' \
      "$DROIDSPACES_TUI_REVISION" "$ANLAND_REPOSITORY" "$ANLAND_RELEASE_TAG" \
      "$ANLAND_PACKAGE_REVISION" "$ANLAND_ARCHIVE_NAME" "$ANLAND_ARCHIVE_SHA256" "$USERNAME" \
      > /usr/share/armada/droidspaces-rootfs-build-info && \
    getent passwd "$USERNAME" >/dev/null && \
    awk -F: -v account="$USERNAME" '$1 == account && $2 ~ /^!/ { found=1 } END { exit !found }' /etc/shadow && \
    test -x /usr/local/bin/start-desktop-session && \
    test -x /usr/bin/dbus-run-session && \
    rpm -q --qf '%{RELEASE}\n' kwin kwin-common kwin-libs | grep -q '\.anland\.' && \
    /usr/bin/strings /usr/bin/kwin_wayland | grep -q 'AnlandBackend'

# ArmadaOS container display/session configuration derived from sjszero/Droidspaces-rootfs-KDE-builder.
# Keep SDDM as the supported Armada session launcher. Containers have no Linux VT.
COPY <<'EOF_ACTION' /usr/libexec/armada/container-action
#!/usr/bin/python3
"""ArmadaOS-only session/power worker. Never touches the Android host."""
import fcntl
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import time

USER = '__DS_USER__'
USER_HOME = Path('/home/__DS_USER__')
STATE = USER_HOME / '.config/armada/container-session.json'
SESSIONS = {
    'desktop': 'armada-plasma.desktop',
    'mobile': 'armada-plasma-mobile.desktop',
    'gamemode': 'gamescope-session-steam.desktop',
}
CONF = Path('/etc/sddm.conf.d/zz-holo-autologin.conf')
RUNTIME = Path('/run/armada-container-session')


def run(args, timeout=20, check=True):
    print('RUN', ' '.join(args), flush=True)
    proc = subprocess.run(args, timeout=timeout, check=False)
    if check and proc.returncode:
        raise RuntimeError('command failed: ' + str(proc.returncode))
    return proc.returncode


def guard():
    if os.geteuid() != 0:
        raise RuntimeError('root service required')
    if Path('/run/systemd/container').read_text().strip() != 'droidspaces':
        raise RuntimeError('not a Droidspaces container')
    if Path('/proc/1/comm').read_text().strip() != 'systemd':
        raise RuntimeError('container PID 1 is not systemd')


def preferences():
    try:
        value = json.loads(STATE.read_text())
        desktop = value.get('desktop_session', 'armada-plasma.desktop')
        login_mode = value.get('default_login_mode', 'game')
        return {
            'desktop_session': desktop if isinstance(desktop, str) else 'armada-plasma.desktop',
            'default_login_mode': login_mode if login_mode in ('game', 'desktop') else 'game',
        }
    except (OSError, ValueError, AttributeError):
        return {'desktop_session': 'armada-plasma.desktop', 'default_login_mode': 'game'}


def atomic(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.new')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def user_systemctl(*args, timeout=20, check=False):
    uid = pwd.getpwnam(USER).pw_uid
    return run([
        '/usr/sbin/runuser', '-u', USER, '--', '/usr/bin/env',
        f'XDG_RUNTIME_DIR=/run/user/{uid}',
        f'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus',
        '/usr/bin/systemctl', '--user', *args,
    ], timeout, check)


def stop_leftover_steam():
    """Only Steam client executables from this user's known installation."""
    uid = pwd.getpwnam(USER).pw_uid
    targets = []
    expected = str(USER_HOME / '.local/share/Steam/steamrtarm64/steam')
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if proc.stat().st_uid == uid and \
                    os.readlink(proc / 'exe').removesuffix(' (deleted)') == expected:
                targets.append(int(proc.name))
        except OSError:
            pass
    for pid in targets:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while targets and time.monotonic() < deadline:
        targets = [pid for pid in targets if Path(f'/proc/{pid}/exe').exists()]
        if targets:
            time.sleep(.1)
    for pid in targets:
        # Recheck the executable so a reused PID is never signalled.
        try:
            if os.readlink(f'/proc/{pid}/exe').removesuffix(' (deleted)') == expected:
                os.kill(pid, 9)
        except OSError:
            pass


def main():
    guard()
    action = sys.argv[1] if len(sys.argv) > 1 else ''
    if action == 'check':
        print(json.dumps({
            'container': 'droidspaces',
            'pid1': 'systemd',
            'preferences': preferences(),
            'power_scope': 'container PID namespace only',
        }))
        return 0
    if action in ('poweroff', 'reboot'):
        # systemctl reaches only this container's PID 1; Android keeps running.
        print('Requesting orderly container ' + action + '; no Android command is used',
              flush=True)
        return run(['/usr/bin/systemctl', '--no-block', action], check=False)
    if action not in ('desktop', 'gamemode', 'default-desktop',
                      'default-gamemode', 'default'):
        raise RuntimeError('unsupported action')
    RUNTIME.mkdir(mode=0o755, parents=True, exist_ok=True)
    with (RUNTIME / 'switch.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        pref = preferences()
        default_only = action.startswith('default')
        mode = action.removeprefix('default-')
        if action == 'default':
            mode = 'gamemode' if pref['default_login_mode'] == 'game' else 'desktop'
        session = SESSIONS['gamemode'] if mode == 'gamemode' else pref['desktop_session']
        if session not in (SESSIONS['gamemode'], SESSIONS['desktop'], SESSIONS['mobile']):
            session = SESSIONS['desktop']
        if not (Path('/usr/share/wayland-sessions') / session).is_file():
            raise RuntimeError('target session is not installed')
        before = CONF.read_text() if CONF.exists() else None
        atomic(CONF, '[Autologin]\nUser=__DS_USER__\nRelogin=true\nSession=' + session + '\n')
        print('Selected', session, flush=True)
        if default_only:
            # The boot selector publishes the active mode before SDDM starts.
            # Changing a preference alone must not relabel a live session.
            if action == 'default':
                atomic(RUNTIME / 'mode', mode + '\n')
            return 0
        # This system service sits outside the graphical cgroup, so it survives
        # the logout below. The user manager, SSH, PipeWire and the Android
        # consumer are never stopped.
        try:
            run(['/usr/bin/systemctl', 'stop', 'sddm.service'], timeout=25)
            user_systemctl('stop', 'armada-steam-desktop.service', timeout=15)
            user_systemctl(
                'stop',
                'plasma-workspace-wayland.target',
                'graphical-session.target',
                'gamescope-session-plus@steam.service',
                'plasma-kwin_wayland.service',
                'plasma-plasmashell.service',
                timeout=25, check=True)
            stop_leftover_steam()
            user_systemctl(
                'unset-environment',
                'DISPLAY', 'XAUTHORITY', 'WAYLAND_DISPLAY', 'GAMESCOPE_WAYLAND_DISPLAY',
                'XDG_DESKTOP_PORTAL_DIR', 'QT_QPA_PLATFORM', 'QT_IM_MODULE',
                'GTK_IM_MODULE', 'SDL_IM_MODULE', 'DESKTOP_SESSION',
                'XDG_CURRENT_DESKTOP', 'XDG_SESSION_DESKTOP')
            user_systemctl(
                'reset-failed',
                'gamescope-session-plus@steam.service',
                'plasma-kwin_wayland.service',
                'plasma-plasmashell.service',
                'armada-steam-desktop.service')
            atomic(RUNTIME / 'mode', mode + '\n')
            run(['/usr/bin/systemctl', 'reset-failed', 'sddm.service'], check=False)
            run(['/usr/bin/systemctl', 'start', 'sddm.service'], timeout=20)
        except Exception:
            if before is None:
                CONF.unlink(missing_ok=True)
            else:
                atomic(CONF, before)
            run(['/usr/bin/systemctl', 'reset-failed', 'sddm.service'], check=False)
            run(['/usr/bin/systemctl', 'start', 'sddm.service'], timeout=20, check=False)
            raise
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('armada-container-action:', error, file=sys.stderr, flush=True)
        sys.exit(1)
EOF_ACTION

COPY <<'EOF_REQUEST' /usr/libexec/armada/container-request
#!/usr/bin/bash
# Only fixed, root-owned service names; never pass through arbitrary systemctl args.
set -u
if [[ $(< /run/systemd/container) != droidspaces || ${USER:-} != __DS_USER__ ]]; then
    printf '%s\n' 'This entrypoint is for the ArmadaOS container user only.' >&2
    exit 1
fi
case ${1:-} in
    desktop|gamemode) unit="armada-container-session@${1}.service" ;;
    poweroff|reboot)  unit="armada-container-${1}.service" ;;
    --check) exec /usr/bin/sudo -n /usr/libexec/armada/container-action check ;;
    *) printf 'usage: %s {desktop|gamemode|poweroff|reboot|--check}\n' "$0" >&2; exit 2 ;;
esac
exec /usr/bin/sudo -n /usr/bin/systemctl --no-block start "$unit"
EOF_REQUEST

COPY <<'EOF_MANAGER' /usr/libexec/armada/container-session-manager
#!/usr/bin/python3
"""Session-only SteamOS Manager compatibility for a read-only /sys container.

Implements upstream's SessionManagement1 contract without initializing hardware,
tracefs, input remapping, or a competing graphical compositor.
"""
import json
import os
from pathlib import Path
import pwd
import signal
import socket
import subprocess
import sys
from gi.repository import Gio, GLib

NAME='com.steampowered.SteamOSManager1'
OBJECT='/com/steampowered/SteamOSManager1'
INTERFACE=NAME+'.SessionManagement1'
STATE=Path('/home/__DS_USER__/.config/armada/container-session.json')
OBJECT_MANAGER_XML='''<node><interface name="org.freedesktop.DBus.ObjectManager"><method name="GetManagedObjects"><arg type="a{oa{sa{sv}}}" direction="out"/></method><signal name="InterfacesAdded"><arg type="o"/><arg type="a{sa{sv}}"/></signal><signal name="InterfacesRemoved"><arg type="o"/><arg type="as"/></signal></interface></node>'''
SESSIONS=['armada-plasma.desktop','armada-plasma-mobile.desktop']
XML='''<node>
 <interface name="com.steampowered.SteamOSManager1.SessionManagement1">
  <method name="SwitchToLoginMode"><arg name="login_mode" type="s" direction="in"/></method>
  <method name="SwitchToGameMode"/>
  <method name="SwitchToDesktopMode"/>
  <method name="SwitchToDesktopSession"><arg name="session" type="s" direction="in"/></method>
  <method name="ValidDesktopSessions"><arg type="as" direction="out"/></method>
  <method name="CleanTemporarySessions"/>
  <property name="DefaultLoginMode" type="s" access="readwrite"/>
  <property name="DefaultDesktopSession" type="s" access="readwrite"/>
 </interface>
 <interface name="com.steampowered.SteamOSManager1.Manager2">
  <method name="ReloadConfig"/>
  <property name="DeviceModel" type="(ss)" access="read"/>
 </interface>
 <interface name="com.steampowered.SteamOSManager1.ContainerSession1">
  <method name="Check"><arg type="s" direction="out"/></method>
 </interface>
</node>'''

def load_state():
    data={'desktop_session':'armada-plasma.desktop','default_login_mode':'game'}
    try:
        saved=json.loads(STATE.read_text())
        if saved.get('desktop_session') in SESSIONS: data['desktop_session']=saved['desktop_session']
        if saved.get('default_login_mode') in ('game','desktop'): data['default_login_mode']=saved['default_login_mode']
    except (OSError,ValueError,AttributeError): pass
    return data

def save_state(data):
    STATE.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    temp=STATE.with_suffix('.new')
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as out: json.dump(data,out);out.write('\n')
    os.replace(temp,STATE)

def queue_action(mode):
    p=subprocess.run(['/usr/libexec/armada/container-request',mode],capture_output=True,text=True,timeout=5)
    if p.returncode: raise RuntimeError(p.stderr.strip() or 'Unable to queue session service')
    print('queued',mode,flush=True)

def method_call(conn,sender,path,interface,method,parameters,invocation):
    try:
        if interface=='org.freedesktop.DBus.ObjectManager' and method=='GetManagedObjects':
            data=load_state()
            objects={OBJECT:{INTERFACE:{'DefaultLoginMode':GLib.Variant('s',data['default_login_mode']),'DefaultDesktopSession':GLib.Variant('s',data['desktop_session'])},NAME+'.Manager2':{'DeviceModel':GLib.Variant('(ss)',('ArmadaOS Container',''))},NAME+'.ContainerSession1':{}}}
            invocation.return_value(GLib.Variant('(a{oa{sa{sv}}})',(objects,)));return
        if interface==NAME+'.ContainerSession1' and method=='Check':
            invocation.return_value(GLib.Variant('(s)',(json.dumps({'session_only':True,'state':load_state(),'container':'droidspaces'}),)));return
        if interface==NAME+'.Manager2' and method=='ReloadConfig': invocation.return_value(None);return
        if interface!=INTERFACE: raise ValueError('Unsupported interface')
        if method=='ValidDesktopSessions':
            valid=[s for s in SESSIONS if (Path('/usr/share/wayland-sessions')/s).exists()]
            invocation.return_value(GLib.Variant('(as)',(valid,)));return
        if method=='CleanTemporarySessions': invocation.return_value(None);return
        if method=='SwitchToDesktopSession':
            requested=parameters.unpack()[0]
            if requested not in SESSIONS: raise ValueError('Unsupported desktop session')
            data=load_state();data['desktop_session']=requested;save_state(data);mode='desktop'
        elif method=='SwitchToLoginMode':
            requested=parameters.unpack()[0]
            if requested not in ('game','desktop'): raise ValueError('Invalid login mode')
            mode='gamemode' if requested=='game' else 'desktop'
        elif method=='SwitchToGameMode': mode='gamemode'
        elif method=='SwitchToDesktopMode': mode='desktop'
        else: raise ValueError('Unsupported method')
        queue_action(mode)
        invocation.return_value(None)
    except Exception as error:
        print('request failed:',error,file=sys.stderr,flush=True)
        invocation.return_dbus_error('org.freedesktop.DBus.Error.Failed',str(error))

def get_property(conn,sender,path,interface,name):
    data=load_state()
    if interface==INTERFACE and name=='DefaultLoginMode': return GLib.Variant('s',data['default_login_mode'])
    if interface==INTERFACE and name=='DefaultDesktopSession': return GLib.Variant('s',data['desktop_session'])
    if interface==NAME+'.Manager2' and name=='DeviceModel': return GLib.Variant('(ss)',('ArmadaOS Container',''))
    return None

def set_property(conn,sender,path,interface,name,value):
    if interface!=INTERFACE: return False
    data=load_state();text=value.unpack()
    if name=='DefaultDesktopSession' and text in SESSIONS: data['desktop_session']=text
    elif name=='DefaultLoginMode' and text in ('game','desktop'): data['default_login_mode']=text
    else: return False
    save_state(data)
    conn.emit_signal(None,OBJECT,'org.freedesktop.DBus.Properties','PropertiesChanged',GLib.Variant('(sa{sv}as)',(INTERFACE,{name:GLib.Variant('s',text)},[])))
    return True

def main():
    # The unit runs as the desktop user; refuse anything else.
    expected=pwd.getpwnam('__DS_USER__').pw_uid
    if os.getuid()!=expected or Path('/run/systemd/container').read_text().strip()!='droidspaces': raise RuntimeError('Wrong container user')
    connection=Gio.bus_get_sync(Gio.BusType.SESSION,None)
    reply=connection.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName',GLib.Variant('(su)',(NAME,4)),GLib.VariantType.new('(u)'),Gio.DBusCallFlags.NONE,4000,None)
    if reply.unpack()[0]!=1: raise RuntimeError('SteamOS Manager bus name is already owned')
    node=Gio.DBusNodeInfo.new_for_xml(XML)
    registrations=[connection.register_object(OBJECT,i,method_call,get_property,set_property) for i in node.interfaces]
    object_manager=Gio.DBusNodeInfo.new_for_xml(OBJECT_MANAGER_XML)
    registrations.append(connection.register_object('/',object_manager.interfaces[0],method_call,None,None))
    loop=GLib.MainLoop()
    for sig in (signal.SIGINT,signal.SIGTERM): GLib.unix_signal_add(GLib.PRIORITY_DEFAULT,sig,lambda: (loop.quit(),False)[1])
    print('SessionManagement1 ready; hardware interfaces intentionally absent',flush=True)
    notify=os.environ.get('NOTIFY_SOCKET')
    if notify:
        address='\0'+notify[1:] if notify.startswith('@') else notify
        with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as status:
            status.connect(address);status.sendall(b'READY=1\nSTATUS=Container session interface ready')
    loop.run()
    for registration in registrations: connection.unregister_object(registration)

if __name__=='__main__': main()
EOF_MANAGER

COPY <<'EOF_STEAMBGD' /usr/libexec/armada/start-steam-background
#!/usr/bin/bash
set -u
[[ $(cat /run/armada-container-session/mode 2>/dev/null) == desktop ]] || exit 0
[[ ${XDG_CURRENT_DESKTOP:-} == *KDE* && -n ${DISPLAY:-} ]] || exit 0
unset QT_IM_MODULE GTK_IM_MODULE SDL_IM_MODULE GAMESCOPE_WAYLAND_DISPLAY
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
export DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/bus
# Import only the real, newly started desktop's display, never a retired Xwayland.
vars=()
for name in DISPLAY XAUTHORITY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE; do
    [[ -v $name ]] && vars+=("$name")
done
systemctl --user import-environment "${vars[@]}" || exit 1
exec systemctl --user --no-block start armada-steam-desktop.service
EOF_STEAMBGD

COPY <<'EOF_STEAMBGD_DESKTOP' /etc/xdg/autostart/armada-steam-background.desktop
[Desktop Entry]
Type=Application
Name=Steam background session
Exec=/usr/libexec/armada/start-steam-background
OnlyShowIn=KDE;
NoDisplay=true
X-KDE-autostart-phase=2
EOF_STEAMBGD_DESKTOP

COPY <<'EOF_STEAMDESKTOP' /etc/systemd/user/armada-steam-desktop.service
[Unit]
Description=Steam background client for ArmadaOS desktop
PartOf=graphical-session.target
After=plasma-plasmashell.service

[Service]
ExecStart=/usr/libexec/armada/launch-steam --desktop -silent
KillMode=control-group
TimeoutStopSec=10
TimeoutStopFailureMode=kill
Environment=ANLAND=1 SDL_JOYSTICK_DISABLE_UDEV=1 SDL_HIDAPI_UDEV=0 SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
EOF_STEAMDESKTOP

COPY <<'EOF_SESSION_UNIT' /etc/systemd/system/armada-container-session@.service
[Unit]
Description=Switch ArmadaOS container graphics to %i
ConditionPathExists=/run/systemd/container
After=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/armada/container-action %i
TimeoutStartSec=90
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal
EOF_SESSION_UNIT

COPY <<'EOF_POWEROFF_UNIT' /etc/systemd/system/armada-container-poweroff.service
[Unit]
Description=Orderly ArmadaOS container poweroff
ConditionPathExists=/run/systemd/container

[Service]
Type=oneshot
ExecStart=/usr/libexec/armada/container-action poweroff
TimeoutStartSec=15
EOF_POWEROFF_UNIT

COPY <<'EOF_REBOOT_UNIT' /etc/systemd/system/armada-container-reboot.service
[Unit]
Description=Orderly ArmadaOS container reboot
ConditionPathExists=/run/systemd/container

[Service]
Type=oneshot
ExecStart=/usr/libexec/armada/container-action reboot
TimeoutStartSec=15
EOF_REBOOT_UNIT

COPY <<'EOF_MANAGER_UNIT' /etc/systemd/user/armada-container-session-manager.service
[Unit]
Description=ArmadaOS container Steam session interface
After=dbus.socket
Requires=dbus.socket

[Service]
Type=notify
NotifyAccess=main
ExecStart=/usr/libexec/armada/container-session-manager
Restart=on-failure
RestartSec=2
TimeoutStartSec=8
TimeoutStopSec=5

[Install]
WantedBy=default.target
EOF_MANAGER_UNIT

COPY <<'EOF_MANAGER_DROPIN' /etc/systemd/user/armada-container-session-manager.service.d/90-armada-user-bus.conf
[Service]
# The user manager supplies this runtime independently of shell or SSH startup.
Environment=XDG_RUNTIME_DIR=%t DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus
EOF_MANAGER_DROPIN

COPY <<'EOF_BOOT' /usr/libexec/armada/container-boot-mode
#!/usr/bin/python3
"""Publish the container's boot session before SDDM autologins into it."""
import json
import sys
from pathlib import Path

RUNTIME = Path('/run/armada-container-session')
CONF = Path('/etc/sddm.conf.d/zz-holo-autologin.conf')
STATE = Path('/home/__DS_USER__/.config/armada/container-session.json')
SESSIONS = ('armada-plasma.desktop', 'armada-plasma-mobile.desktop')


def main():
    mode = 'game'
    desktop = 'armada-plasma.desktop'
    try:
        saved = json.loads(STATE.read_text())
        if saved.get('default_login_mode') in ('game', 'desktop'):
            mode = saved['default_login_mode']
        if saved.get('desktop_session') in SESSIONS:
            desktop = saved['desktop_session']
    except (OSError, ValueError, AttributeError):
        pass

    if mode == 'desktop':
        session, label = desktop, 'desktop'
    else:
        session, label = 'gamescope-session-steam.desktop', 'gamemode'

    RUNTIME.mkdir(mode=0o755, parents=True, exist_ok=True)
    (RUNTIME / 'mode').write_text(label + '\n')
    CONF.parent.mkdir(parents=True, exist_ok=True)
    CONF.write_text(
        '[Autologin]\nUser=__DS_USER__\nRelogin=true\nSession=' + session + '\n')
    print('armada: boot mode %s (session %s)' % (label, session), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
EOF_BOOT

COPY <<'EOF_SDDM95' /etc/systemd/system/sddm.service.d/95-armada-container.conf
[Unit]
JobTimeoutSec=0
JobRunningTimeoutSec=0
[Service]
TimeoutStartSec=infinity
WatchdogSec=0
Environment=ANLAND_SOCKET=/run/display.sock
ExecStartPre=
ExecStartPre=/usr/libexec/armada/prepare-anland-session
EOF_SDDM95

COPY <<'EOF_PREPARE' /usr/libexec/armada/prepare-anland-session
#!/usr/bin/bash
# Android containers have no Linux VTs, but the container runtime still creates
# a /dev/tty1 node. That node is a fake: it is either a symlink to /dev/null or
# a char device carrying /dev/null's device numbers (1,3), and the kernel
# exposes no tty1 class entry behind it. SDDM trusts the node, issues TIOCSCTTY
# and dies with HELPER_TTY_ERROR (exit code 5) before any producer can wait, so
# the node has to go.
#
# The runtime's node shape is not part of any contract and has already changed
# once (Droidspaces v7.2.0 switched the symlink for a char device), which broke
# the previous "symlink to /dev/null" test and left SDDM looping on a dead VT.
# Probe the kernel instead of the node: a real VT always has a tty1 entry under
# /sys/class/tty, so anything present at /dev/tty1 without one is a placeholder.
set -uo pipefail
if [[ ! -e /sys/class/tty/tty1 ]] && [[ -e /dev/tty1 || -L /dev/tty1 ]]; then
    rm -- /dev/tty1 || exit 1
    printf '%s\n' 'armada: removed container tty1 placeholder; SDDM will run without a VT'
fi
[[ ${1:-} != --prepare-only ]] || exit 0
# Anland can be enabled in the app without a pre-mounted daemon socket. Leave
# SDDM's pre-start job waiting until the producer appears, as in the working
# container; killing/restarting gamescope here would consume SDDM's start limit.
socket=${ANLAND_SOCKET:-/run/display.sock}
if [[ ! -S $socket ]]; then
    printf 'armada: waiting for Anland daemon socket %s; no startup deadline\n' "$socket"
    while [[ ! -S $socket ]]; do
        sleep 1
    done
fi
EOF_PREPARE

COPY <<'EOF_SDDM96' /etc/systemd/system/sddm.service.d/96-armada-user-manager.conf
[Unit]
# Container SDDM cannot register a VT-backed PAM session. Use the boot-started
# lingering user manager and select the default mode before launching graphics.
Requires=user@__DS_UID__.service armada-session-default.service
After=user@__DS_UID__.service armada-session-default.service
EOF_SDDM96

COPY <<'EOF_SDDM98' /etc/systemd/system/sddm.service.d/98-armada-container-ux.conf
[Service]
TimeoutStopSec=3
KillMode=control-group
SendSIGKILL=yes
TimeoutStopFailureMode=kill
EOF_SDDM98

COPY <<'EOF_GAMESCOPE' /etc/systemd/user/gamescope-session-plus@steam.service.d/90-armada-container.conf
[Service]
Environment=BACKEND=anland ANLAND=1 ANLAND_SOCKET=/run/display.sock ANLAND_DRM_DEVICE=/dev/dri/renderD128
EOF_GAMESCOPE
COPY <<'EOF_GAMESCOPE_WAIT' /etc/systemd/user/gamescope-session-plus@steam.service.d/95-anland-consumer-wait.conf
[Unit]
JobTimeoutSec=0
JobRunningTimeoutSec=0
[Service]
TimeoutStartSec=infinity
WatchdogSec=0
EOF_GAMESCOPE_WAIT

COPY <<'EOF_SDDM_ARMADA' /etc/sddm.conf.d/armada.conf
[Autologin]
Relogin=true
Session=gamescope-session-steam.desktop
User=__DS_USER__
EOF_SDDM_ARMADA

COPY <<'EOF_GAMESCOPE_RESTART' /etc/systemd/user/gamescope-session-plus@steam.service.d/99-armada-container-restart.conf
[Service]
Restart=always
RestartSec=2
EOF_GAMESCOPE_RESTART

COPY <<'EOF_SESSION_DEFAULT' /etc/systemd/system/armada-session-default.service.d/98-armada-container-ux.conf
[Service]
ExecStart=
ExecStart=/usr/libexec/armada/container-boot-mode
EOF_SESSION_DEFAULT

COPY <<'EOF_CONTROL_SESSION_USER' /etc/systemd/system/armada-control.service.d/98-armada-container-ux.conf
[Service]
Environment=ARMADA_SESSION_USER=__DS_USER__
EOF_CONTROL_SESSION_USER

RUN <<'EOF_ENABLE_SESSION'
set -eux
test -x /usr/libexec/armada/armada-plasma-session
bash -n /usr/libexec/armada/steam-anland-env
install -d /etc/gamescope-session-plus/sessions.d
printf '\nsource /usr/libexec/armada/steam-anland-env\n' >> /etc/gamescope-session-plus/sessions.d/steam
printf '\nMESA_LOADER_DRIVER_OVERRIDE=kgsl\nGALLIUM_DRIVER=kgsl\nFD_FORCE_KGSL=1\n' >> /etc/environment
python3 /tmp/patch-armada-plasma-session.py /usr/libexec/armada/armada-plasma-session
python3 /tmp/patch-armada-gamescope-startup.py /usr/share/gamescope-session-plus/gamescope-session-plus
python3 /tmp/patch-armada-container-desktop-mode.py /usr/libexec/armada/armada-control "${USERNAME}"
uid=$(id -u "${USERNAME}")
for file in /usr/libexec/armada/container-action /usr/libexec/armada/container-request /usr/libexec/armada/container-session-manager /usr/libexec/armada/session-control /usr/libexec/armada/container-boot-mode /etc/systemd/system/sddm.service.d/96-armada-user-manager.conf /etc/systemd/system/armada-control.service.d/98-armada-container-ux.conf /etc/sddm.conf.d/armada.conf; do sed -i "s/__DS_USER__/${USERNAME}/g; s/__DS_UID__/${uid}/g" "$file"; done
chmod 0755 /usr/libexec/armada/container-action /usr/libexec/armada/container-request /usr/libexec/armada/container-session-manager /usr/libexec/armada/session-control /usr/libexec/armada/container-boot-mode /usr/libexec/armada/prepare-anland-session
mkdir -p /var/lib/systemd/linger; touch /var/lib/systemd/linger/"${USERNAME}"
ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
ln -sf /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service
ln -sf /usr/lib/systemd/system/armada-session-default.service /etc/systemd/system/multi-user.target.wants/armada-session-default.service
mkdir -p /etc/systemd/user/default.target.wants
ln -sf ../armada-container-session-manager.service /etc/systemd/user/default.target.wants/armada-container-session-manager.service
rm -f /etc/systemd/system/sddm.service
python3 -c 'import ast; ast.parse(open("/usr/libexec/armada/container-action").read()); ast.parse(open("/usr/libexec/armada/container-session-manager").read()); ast.parse(open("/usr/libexec/armada/container-boot-mode").read())'
bash -n /usr/libexec/armada/container-request /usr/libexec/armada/session-control /usr/libexec/armada/prepare-anland-session /usr/libexec/armada/armada-plasma-session
python3 -c 'from gi.repository import Gio, GLib; Gio.DBusNodeInfo.new_for_xml("<node/>")'
grep -q ANLAND_SKIP_IMPLICIT_SYNC_WAIT /usr/libexec/armada/armada-plasma-session
grep -q armada_wait_gamescope_startup /usr/share/gamescope-session-plus/gamescope-session-plus
test -x /usr/libexec/gamescope-anland/startup.sh
gamescope --help 2>&1 | grep -qi anland
EOF_ENABLE_SESSION

ARG ANLAND_REPOSITORY=https://github.com/SuperTurtleDev/anland.git
ARG ANLAND_BRANCH=legacy
ARG TERRA_REPOSITORY=https://github.com/terrapkg/packages.git
ARG TERRA_COMMIT=23ec8c9aeaad28179925232fe7564f80da06d4ab
ARG GAMESCOPE_REPOSITORY=https://github.com/OpenGamingCollective/gamescope
# armadaos-freedom's series is written against 3.16.31-ogc1: 39 of its 40
# patches apply at fuzz 0 there, while only 1 of 40 does on 3.17.0-ogc1 (the tag
# the older armada 31-patch series targets). Following the patch source means
# following its base.
ARG GAMESCOPE_TAG=3.16.31-ogc1
ARG GAMESCOPE_COMMIT=afd6eac6e1b5045119831b63854bad68ec4fd92c
ARG ANLAND_JOBS=4

# Armada pins used by the gamescope build below and by the anland-rebuild-gamescope
# helper further down, which runs outside this build stage and therefore
# re-declares the same two values. Keep both ARMADA_COMMIT values and the
# patch-count assertion below in sync with anland's build.sh.
ARG ARMADA_REPOSITORY=https://github.com/ArmadaOS-Freedom/armadaos-freedom.git
ARG ARMADA_COMMIT=be6fc7834012c54a1ae7b8ae8dfba39196064458

# Drop privileges without opening a PAM session.
# runuser opens one, and pam_limits then fails with
# "cannot open session: Permission denied" as soon as a group-based limit has to
# be raised: the build user is in pipewire and gamemode, so
# @pipewire rtprio/nice and @gamemode nice apply, and raising them needs
# CAP_SYS_RESOURCE. No buildkit RUN has that capability, so build.sh could
# never start there. as-user falls back to setpriv, which needs no session.
COPY --from=armada-adapter /scripts/armada-as-user.sh /usr/local/bin/as-user

# 9a. Build and install gamescope with the Anland backend.
# One RUN for the whole thing. A layer can only shrink within a single
# instruction, so the toolchain is installed, used, and removed here; doing it
# across steps would bake compiler packages into the image permanently.
RUN <<'EOF_RUN'
set -eux

chmod 0755 /usr/local/bin/as-user
bash -n /usr/local/bin/as-user
# as-user falls back to setpriv; make sure the fallback really exists.
command -v setpriv >/dev/null || dnf -y install util-linux

BUILD_ROOT=/var/tmp/anland-gamescope-build
CACHE="$BUILD_ROOT/cache"
ANLAND=/usr/local/src/anland

rm -rf "$BUILD_ROOT"
install -d -m 0755 "$BUILD_ROOT" "$CACHE/recipe" "$CACHE/sdk/usr/lib64/pkgconfig"

# build-only toolchain
# Everything installed here is rolled back with `dnf history undo` at the end,
# so the compiler stack never survives into the image.
dnf -y install --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
    gcc gcc-c++ make cmake meson ninja-build rpm-build git-core tar patch \
    pkgconf-pkg-config python3 glm-devel google-benchmark-devel \
    libXcursor-devel libXmu-devel spirv-headers-devel glslang \
    stb_image-devel stb_image_resize-devel stb_image_write-devel \
    "pkgconfig(libavif)" "pkgconfig(libcap)" "pkgconfig(catch2-with-main)" \
    "pkgconfig(hwdata)" "pkgconfig(libdecor-0)" "pkgconfig(libdisplay-info)" \
    "pkgconfig(libdrm)" "pkgconfig(libeis-1.0)" "pkgconfig(libliftoff)" \
    "pkgconfig(libinput)" "pkgconfig(libpipewire-0.3)" "pkgconfig(libseat)" \
    "pkgconfig(libudev)" "pkgconfig(lcms2)" "pkgconfig(luajit)" "pkgconfig(sdl2)" \
    "pkgconfig(vulkan)" "pkgconfig(wayland-protocols)" "pkgconfig(wayland-scanner)" \
    "pkgconfig(wayland-server)" "pkgconfig(wlroots-0.18)" "pkgconfig(x11)" \
    "pkgconfig(x11-xcb)" "pkgconfig(xcb)" "pkgconfig(xcb-errors)" "pkgconfig(xcb-icccm)" \
    "pkgconfig(xcb-renderutil)" "pkgconfig(xcomposite)" "pkgconfig(xdamage)" \
    "pkgconfig(xext)" "pkgconfig(xfixes)" "pkgconfig(xkbcommon)" "pkgconfig(xrender)" \
    "pkgconfig(xres)" "pkgconfig(xtst)" "pkgconfig(xxf86vm)" \
    anda-srpm-macros
# anda-srpm-macros (from the terra repo, already enabled in the base image) is
# not optional here: the Terra spec writes `Requires: terra-gamescope-libs =
# %{evr}` and `%evr` is an anda macro. Without it rpm leaves the dependency as
# the literal string "%{evr}", which no package can ever satisfy, so the build
# succeeds but the later `rpm -Uvh` fails with
# "terra-gamescope-libs = %{evr} is needed by terra-gamescope". The spec's
# %prep/%install use of %git_clone/%conf is rewritten by build.sh, and %caps in
# %files is a file directive rather than a macro, so %evr is the only expansion
# that has to work.
if [ "$(rpm --eval '%{evr}')" = '%{evr}' ]; then
    echo 'anda-srpm-macros is missing: %{evr} does not expand, so the built' >&2
    echo 'gamescope RPMs would require a dependency no package can satisfy.' >&2
    exit 1
fi
# Remember the exact transaction so the same set can be undone later. dnf5 can
# print history as JSON; matching the text output with awk would also match
# "reinstall"/"uninstall" rows and could undo the wrong transaction.
TOOLCHAIN_TX=$(dnf history list --reverse --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["id"])')
test -n "$TOOLCHAIN_TX"

# inputs
# gamescope source, exactly the revision the Anland patches expect.
git clone --quiet --depth 1 --branch "$GAMESCOPE_TAG" \
    "$GAMESCOPE_REPOSITORY" "$CACHE/source"
test "$(git -C "$CACHE/source" rev-parse HEAD)" = "$GAMESCOPE_COMMIT"
git -C "$CACHE/source" submodule --quiet update --init --depth 1 --recursive

# Armada's native gamescope patch series at the pinned commit.
git clone --quiet --filter=blob:none --no-checkout \
    "$ARMADA_REPOSITORY" "$BUILD_ROOT/armada"
git -C "$BUILD_ROOT/armada" checkout --quiet "$ARMADA_COMMIT"
ARMADA_ROOT="$BUILD_ROOT/armada"
# 40 at armadaos-freedom be6fc783, against 31 at the armada d5c23cd this image
# used before; anland's own literal is retargeted right after its clone below.
test "$(find "$ARMADA_ROOT/packages/gamescope/patches" \
    -name '[0-9][0-9][0-9][0-9]-*.patch' | wc -l)" = 40

# Terra/OGC RPM recipe at the pinned commit (build.sh adapts it in place).
git clone --quiet --filter=blob:none --no-checkout \
    "$TERRA_REPOSITORY" "$BUILD_ROOT/terra"
git -C "$BUILD_ROOT/terra" checkout --quiet "$TERRA_COMMIT"
TERRA_PKG="$BUILD_ROOT/terra/anda/games/terra-gamescope"
install -m 0644 "$TERRA_PKG/terra-gamescope.spec" "$CACHE/recipe/"
# build.sh copies every *.patch and stb.pc from recipe/ into SOURCES.
for f in "$TERRA_PKG"/*.patch "$TERRA_PKG"/stb.pc; do
    [ -e "$f" ] && install -m 0644 "$f" "$CACHE/recipe/"
done

# build.sh checks pkgconfig(xwayland) through a private SDK because the runtime
# Xwayland ships no development metadata. Only this .pc file is needed; the
# feature flags mirror the installed Xwayland.
cat > "$CACHE/sdk/usr/lib64/pkgconfig/xwayland.pc" <<'PC'
prefix=/usr
exec_prefix=${prefix}
xwayland=/usr/bin/Xwayland
have_glamor=true
have_glamor_api=true
have_eglstream=false
have_initfd=true
have_listenfd=true
have_terminate_delay=true
have_no_touch_pointer_emulation=true
have_force_xrandr_emulation=true
have_geometry=true
have_fullscreen=true
have_host_grab=true
have_decorate=true
have_enable_ei_portal=true
have_byteswappedclients=true
have_hidpi=true
Name: Xwayland
Description: X Server for Wayland
URL: https://gitlab.freedesktop.org/xorg/xserver/
Version: 24.1.14
PC

# anland tree (kept)
rm -rf "$ANLAND"
git clone --quiet --branch "$ANLAND_BRANCH" "$ANLAND_REPOSITORY" "$ANLAND"
# anland carries the port itself (a local commit above origin/legacy): its build.sh already pins
# gamescope afd6eac / 3.16.31-ogc1 and the 40 Armada patches, and its own
# gamescope.patch is the rebased copy. Nothing is rewritten from here any more;
# this only checks the pins against what this build is about to use, so a clone
# that still lags fails with a pointed message instead of a patch reject later.
python3 - "$ANLAND/producers/gamescope/ArmadaOS_v5/build.sh" "$ARMADA_ROOT" "$GAMESCOPE_COMMIT" <<'PY_ARMADA'
import pathlib, re, sys
script = pathlib.Path(sys.argv[1])
armada = pathlib.Path(sys.argv[2])
revision = sys.argv[3]
count = len(list((armada / 'packages/gamescope/patches').glob('[0-9][0-9][0-9][0-9]-*.patch')))
text = script.read_text()
declared = re.search(r'assert len\(patches\)==(\d+)', text)
if declared is None:
    sys.exit(f'no patch-count assert found in {script}')
if int(declared.group(1)) != count:
    sys.exit('anland expects ' + declared.group(1) + ' Armada patches, the pinned tree carries '
             + str(count) + ': push the ported anland before rebuilding')
pinned = re.search(r'rev-parse HEAD\) == ([0-9a-f]{40})', text)
if pinned is None:
    sys.exit(f'no gamescope revision assert found in {script}')
if pinned.group(1) != revision:
    sys.exit('anland pins gamescope ' + pinned.group(1) + ', this build uses ' + revision
             + ': push the ported anland before rebuilding')
print(f'anland recipe agrees with the pinned inputs: {count} patches, gamescope {revision}')
PY_ARMADA

# build
# build.sh requires an ordinary aarch64 user, so only this step drops root.
# as-user falls back to setpriv when PAM sessions are unavailable (buildkit).
chown -R "${USERNAME}:${USERNAME}" "$BUILD_ROOT" "$ANLAND"
/usr/local/bin/as-user "${USERNAME}" \
    env \
    HOME="/home/${USERNAME}" \
    CACHE="$CACHE" \
    ARMADA_ROOT="$ARMADA_ROOT" \
    JOBS="$ANLAND_JOBS" \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    PATH="/usr/local/bin:/usr/bin:/usr/sbin" \
    bash "$ANLAND/producers/gamescope/ArmadaOS_v5/build.sh"

# install
# build.sh prints the artifact directory; it is the newest artifacts.* entry.
ARTIFACTS=$(ls -dt "$CACHE"/artifacts.* | head -1)
test -d "$ARTIFACTS"
mapfile -t RPMS < <(find "$ARTIFACTS" -maxdepth 1 -name '*.rpm' \
    ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
test "${#RPMS[@]}" -ge 1
# rpm happily builds a package whose inter-subpackage dependency is the literal
# string "%{evr}", then refuses to install it. Catch that here, where the cause
# (a missing anda macro during rpmbuild) is still obvious.
if rpm -qp --requires "${RPMS[@]}" 2>/dev/null | grep -q '%{'; then
    echo 'built RPMs contain unexpanded macros in their requirements:' >&2
    rpm -qp --requires "${RPMS[@]}" 2>/dev/null | grep '%{' >&2
    exit 1
fi
# The base Armada image can ship a newer Terra gamescope than this pinned
# Anland build. --oldpackage intentionally permits that downgrade; --replacepkgs
# also makes reruns deterministic. Scriptlets stay enabled: the package registers
# a Vulkan implicit layer through %post.
rpm -Uvh --oldpackage --replacepkgs "${RPMS[@]}"

# verify
# The installed compositor must report the anland backend before the sources go.
test -x /usr/bin/gamescope
# Capture the help text and match with a case: grep -q in a pipeline closes the
# pipe early, which can kill gamescope with SIGPIPE (and under pipefail abort
# the run before the dependency cleanup). case is POSIX, so it also works in
# the image step, whose heredoc RUN has no SHELL override.
GAMESCOPE_HELP=$(/usr/bin/gamescope --help 2>&1 || true)
case "$GAMESCOPE_HELP" in
    *anland*) ;;
    *) echo 'gamescope --help no longer advertises the anland backend' >&2; exit 1 ;;
esac
test -x /usr/libexec/gamescope-anland/startup.sh
rpm -q terra-gamescope

# clean up
# Everything the build downloaded. The anland tree keeps its .git on purpose:
# build.sh records `git -C $HERE rev-parse HEAD` and the rebuild path resets to
# origin/legacy, so removing it would make every later rebuild fail.
rm -rf "$BUILD_ROOT"
# Roll the toolchain transaction back. gamescope's own packages stay: they were
# installed by the rpm call above, not by dnf, so undo cannot touch them.
dnf -y history undo "$TOOLCHAIN_TX" --skip-unavailable \
    --setopt=clean_requirements_on_remove=False || true
dnf clean all
rm -rf /var/cache/dnf/* /var/cache/libdnf5/* 2>/dev/null || true
# The installed compositor must still work without the compiler stack.
/usr/bin/gamescope --help >/dev/null
EOF_RUN

COPY --from=armada-adapter /scripts/install-mesa.sh /usr/local/sbin/install-mesa
RUN bash -euo pipefail -c 'cp /etc/os-release /tmp/droidspaces-os-release; sed -i -E "s/^ID=\\\"?armada\\\"?$/ID=fedora/" /etc/os-release; /usr/local/sbin/install-mesa --1; cp /tmp/droidspaces-os-release /etc/os-release'

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
