#!/usr/bin/env bash
# A private, persistent Linux desktop for Circe's SSH / Google Cloud connections.
main() {
set -euo pipefail
umask 077

usage() {
    cat <<'HELP'
Usage: bash setup-circe-host.sh [--user USER] [--display 1] [--geometry 1600x1000]
       bash setup-circe-host.sh [--user USER] [--display 1] --check
       bash setup-circe-host.sh [--user USER] --reset-password

Run as the Linux account you connect to (sudo is used for packages and boot setup).
When running as root, supply --user or invoke through sudo from that account.
--check only reports status; it never installs packages or changes services.
Rerunning preserves the VNC password. --reset-password generates a new one.
HELP
}
die() { printf 'Circe: %s\n' "$*" >&2; exit 1; }
TARGET_USER="${SUDO_USER:-$(id -un)}"
DISPLAY_NUMBER=1
GEOMETRY=1600x1000
DISPLAY_EXPLICIT=false
GEOMETRY_EXPLICIT=false
CHECK=false
RESET_PASSWORD=false
while (($#)); do
    case "$1" in
        --user|--display|--geometry)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --user) TARGET_USER="$2" ;;
                --display) DISPLAY_NUMBER="${2#:}"; DISPLAY_EXPLICIT=true ;;
                --geometry) GEOMETRY="$2"; GEOMETRY_EXPLICIT=true ;;
            esac
            shift 2 ;;
        --check) CHECK=true; shift ;;
        --reset-password) RESET_PASSWORD=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
[[ "$(uname -s)" == Linux ]] || die 'Run this script on the Linux VM, not on your Mac.'
command -v getent >/dev/null || die 'getent is required.'
ACCOUNT="$(getent passwd "$TARGET_USER")" || die "No such Linux account: $TARGET_USER"
IFS=: read -r TARGET_USER _ TARGET_UID _ _ TARGET_HOME _ <<< "$ACCOUNT"
[[ "$TARGET_UID" != 0 ]] || die 'Choose a non-root desktop account with --user USER.'
[[ "$TARGET_HOME" == /* && -d "$TARGET_HOME" && "$TARGET_HOME" != *$'\n'* ]] || die 'The account needs an existing home directory.'
[[ $EUID == 0 || $EUID == "$TARGET_UID" ]] || die 'Use sudo when configuring another account.'
RUNTIME="/run/user/$TARGET_UID"
CONFIG="$TARGET_HOME/.config/circe"
LIBEXEC="$TARGET_HOME/.local/libexec/circe"
UNITS="$TARGET_HOME/.config/systemd/user"
PASSWORD_FILE="$TARGET_HOME/.vnc/passwd"
# Read only numeric settings here. Never source a user-owned shell file as root.
if [[ -f "$CONFIG/host.conf" ]]; then
    if ! $DISPLAY_EXPLICIT; then DISPLAY_NUMBER="$(awk -F= '/^DISPLAY_NUMBER=[0-9]+$/ { print $2; exit }' "$CONFIG/host.conf")"; fi
    if ! $GEOMETRY_EXPLICIT; then GEOMETRY="$(awk -F= '/^GEOMETRY=[0-9]+x[0-9]+$/ { print $2; exit }' "$CONFIG/host.conf")"; fi
fi
[[ "$DISPLAY_NUMBER" =~ ^[0-9]{1,2}$ ]] || die 'Display must be a number from 1 to 99.'
DISPLAY_NUMBER=$((10#$DISPLAY_NUMBER))
((DISPLAY_NUMBER >= 1 && DISPLAY_NUMBER <= 99)) || die 'Display must be from 1 to 99.'
[[ "$GEOMETRY" =~ ^([0-9]{3,4})x([0-9]{3,4})$ ]] || die 'Geometry must look like 1600x1000.'
WIDTH=$((10#${BASH_REMATCH[1]})); HEIGHT=$((10#${BASH_REMATCH[2]}))
((WIDTH >= 640 && WIDTH <= 7680 && HEIGHT >= 480 && HEIGHT <= 4320)) || die 'Geometry must be between 640x480 and 7680x4320.'
VNC_PORT=$((5900 + DISPLAY_NUMBER))

as_root() { if ((EUID == 0)); then "$@"; else sudo -n -- "$@"; fi; }
as_user() {
    local environment=(env "HOME=$TARGET_HOME" "USER=$TARGET_USER" "LOGNAME=$TARGET_USER"
        "XDG_RUNTIME_DIR=$RUNTIME" "DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME/bus" "PULSE_SERVER=unix:$RUNTIME/pulse/native")
    if ((EUID == TARGET_UID)); then "${environment[@]}" "$@"
    else runuser -u "$TARGET_USER" -- "${environment[@]}" "$@"; fi
}
report_status() {
    local failed=0 listeners address found=0
    printf 'Circe desktop for %s — display :%s, TCP %s\n' "$TARGET_USER" "$DISPLAY_NUMBER" "$VNC_PORT"
    if [[ -s "$PASSWORD_FILE" ]]; then printf '  Password: configured (never printed by --check)\n'
    else printf '  Password: missing\n'; failed=1; fi
    for unit in circe-desktop.service circe-audio.service; do
        if as_user systemctl --user is-active --quiet "$unit" 2>/dev/null; then printf '  %s: running\n' "$unit"
        else printf '  %s: not running\n' "$unit"; failed=1; fi
        if ! as_user systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then printf '  %s: not enabled at boot\n' "$unit"; failed=1; fi
    done
    if [[ "$(loginctl show-user "$TARGET_USER" -p Linger --value 2>/dev/null || true)" == yes ]]; then printf '  Boot persistence: enabled\n'
    else printf '  Boot persistence: not enabled\n'; failed=1; fi
    if command -v ss >/dev/null; then
        listeners="$(ss -H -ltn "sport = :$VNC_PORT")"
        while read -r address; do
            [[ -n "$address" ]] || continue
            found=1
            case "$address" in
                "127.0.0.1:$VNC_PORT"|"[::1]:$VNC_PORT"|"::1:$VNC_PORT") printf '  VNC listener: %s (loopback only)\n' "$address" ;;
                *) printf '  UNSAFE VNC listener: %s — stop the server and check its configuration\n' "$address"; failed=1 ;;
            esac
        done < <(awk '{ print $4 }' <<< "$listeners")
        if ((found == 0)); then printf '  VNC listener: missing\n'; failed=1; fi
    else printf '  VNC listener: cannot verify (ss missing)\n'; failed=1; fi
    if as_user pactl list short sources 2>/dev/null | awk '{ print $2 }' | grep -qx 'circe.monitor'; then printf '  Audio: circe.monitor ready (48 kHz stereo)\n'
    else printf '  Audio: circe.monitor missing\n'; failed=1; fi
    return "$failed"
}
if $CHECK; then report_status; exit $?; fi
command -v systemctl >/dev/null || die 'This installer requires a Linux VM with systemd.'
if ((EUID != 0)); then
    command -v sudo >/dev/null || die 'sudo is required to install packages.'
    sudo -n true || die 'Automatic setup needs passwordless sudo. In an interactive SSH terminal, run: sudo bash setup-circe-host.sh (or supply --user when already root).'
fi
[[ -r /etc/os-release ]] || die 'Cannot identify this Linux distribution.'
# shellcheck disable=SC1091
. /etc/os-release
FAMILY=" ${ID:-} ${ID_LIKE:-} "
BACKEND=pulseaudio
if command -v pipewire-pulse >/dev/null; then BACKEND=pipewire-pulse; fi
AUDIO_PACKAGE=pulseaudio-utils
if [[ "$BACKEND" == pulseaudio ]]; then AUDIO_PACKAGE=pulseaudio; fi
if [[ "$FAMILY" == *debian* || "$FAMILY" == *ubuntu* ]]; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update </dev/null
    VNC_TOOLS_PACKAGE=tigervnc-common
    if apt-cache show tigervnc-tools >/dev/null 2>&1; then VNC_TOOLS_PACKAGE=tigervnc-tools; fi
    as_root env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install \
        xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common "$VNC_TOOLS_PACKAGE" dbus-x11 \
        xauth x11-utils pulseaudio-utils openssl iproute2 ca-certificates curl fonts-dejavu-core "$AUDIO_PACKAGE" </dev/null
elif [[ "$FAMILY" == *rhel* || "$FAMILY" == *fedora* || "$FAMILY" == *rocky* || "$FAMILY" == *almalinux* ]]; then
    command -v dnf >/dev/null || die 'RHEL-family setup requires dnf and an enabled XFCE repository (usually EPEL/CRB).'
    if [[ "$FAMILY" != *fedora* ]]; then
        as_root dnf -y install epel-release </dev/null || printf 'Enable EPEL/CRB for your distribution if XFCE packages are unavailable.\n' >&2
    fi
    as_root dnf -y install tigervnc-server xfce4-session xfce4-panel xfce4-settings xfce4-terminal \
        xfdesktop xfwm4 Thunar dbus-x11 xorg-x11-xauth xdpyinfo pulseaudio-utils \
        openssl iproute curl ca-certificates dejavu-sans-fonts "$AUDIO_PACKAGE" </dev/null || die 'Package installation failed; check EPEL/CRB availability. No VNC firewall rule is needed.'
else die "Unsupported distribution: ${PRETTY_NAME:-$FAMILY}. Use Debian/Ubuntu, or prepare TigerVNC and XFCE manually."; fi

VNC_SERVER="$(command -v Xtigervnc || command -v Xvnc)" || die 'TigerVNC X server was not installed.'
VNC_PASSWD="$(command -v tigervncpasswd || command -v vncpasswd)" || die 'TigerVNC password tool was not installed.'
for tool in dbus-run-session xfce4-session xauth xdpyinfo pactl parec openssl; do command -v "$tool" >/dev/null || die "Required command missing: $tool"; done
as_user mkdir -p "$CONFIG" "$LIBEXEC" "$UNITS" "$TARGET_HOME/.vnc"
as_user chmod 700 "$CONFIG" "$LIBEXEC" "$TARGET_HOME/.vnc"
write_user_file() {
    # Expansion belongs to the target user's shell; the arguments carry paths verbatim.
    # shellcheck disable=SC2016
    as_user bash -c 'set -e; temp=$(mktemp "${1}.XXXXXX"); trap '\''rm -f "$temp"'\'' EXIT; cat > "$temp"; chmod "$2" "$temp"; mv -f -- "$temp" "$1"' _ "$1" "$2"
}
RESULT_PASSWORD=null
if [[ ! -s "$PASSWORD_FILE" ]] || $RESET_PASSWORD; then
    NEW_PASSWORD="$(openssl rand -base64 6)"
    printf '%s\n' "$NEW_PASSWORD" | as_user "$VNC_PASSWD" -f | write_user_file "$PASSWORD_FILE" 600
    RESULT_PASSWORD="\"$NEW_PASSWORD\""
    if [[ -t 1 ]]; then
        printf '\nNew VNC password (shown only this time): %s\nSave it; Circe asks for it on your first connection.\n\n' "$NEW_PASSWORD"
    fi
    unset NEW_PASSWORD
else
    as_user chmod 600 "$PASSWORD_FILE"
    printf 'Keeping the existing VNC password. Use --reset-password if you need a new one.\n'
fi
printf 'DISPLAY_NUMBER=%s\nGEOMETRY=%s\nVNC_SERVER=%q\n' "$DISPLAY_NUMBER" "$GEOMETRY" "$VNC_SERVER" | write_user_file "$CONFIG/host.conf" 600

write_user_file "$LIBEXEC/start-desktop" 700 <<'DESKTOP'
#!/usr/bin/env bash
set -euo pipefail
umask 077
# This file runs as the desktop account, never as root.
# shellcheck disable=SC1091
source "$HOME/.config/circe/host.conf"
export DISPLAY=":$DISPLAY_NUMBER" XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XAUTHORITY="${XDG_RUNTIME_DIR:?}/circe-Xauthority"
touch "$XAUTHORITY"; chmod 600 "$XAUTHORITY"
xauth -f "$XAUTHORITY" add "$DISPLAY" MIT-MAGIC-COOKIE-1 "$(openssl rand -hex 16)"
X_PID=; DESKTOP_PID=
cleanup() {
    trap - EXIT
    [[ -z "$DESKTOP_PID" ]] || kill "$DESKTOP_PID" 2>/dev/null || true
    [[ -z "$X_PID" ]] || kill "$X_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f "$XAUTHORITY"
}
trap cleanup EXIT
trap 'exit 0' TERM INT
"$VNC_SERVER" "$DISPLAY" -localhost=1 -interface 127.0.0.1 -SecurityTypes VncAuth -PasswordFile "$HOME/.vnc/passwd" \
    -rfbport "$((5900 + DISPLAY_NUMBER))" -geometry "$GEOMETRY" -depth 24 -nolisten tcp -auth "$XAUTHORITY" -desktop "Circe — $(hostname)" &
X_PID=$!
ready=false
for ((attempt=0; attempt<100; attempt++)); do
    kill -0 "$X_PID" 2>/dev/null || { wait "$X_PID"; exit 1; }
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.1
done
$ready || { printf 'Circe: virtual display did not become ready.\n' >&2; exit 1; }
if command -v xset >/dev/null; then xset s off 2>/dev/null || true; xset -dpms 2>/dev/null || true; fi
dbus-run-session -- xfce4-session &
DESKTOP_PID=$!
while kill -0 "$X_PID" 2>/dev/null && kill -0 "$DESKTOP_PID" 2>/dev/null; do sleep 1; done
if ! kill -0 "$X_PID" 2>/dev/null; then wait "$X_PID" || true; exit 1; fi
wait "$DESKTOP_PID"
DESKTOP

write_user_file "$LIBEXEC/start-audio" 700 <<'AUDIO'
#!/usr/bin/env bash
set -euo pipefail
# Recover the virtual output if PulseAudio or PipeWire-pulse restarts.
while :; do
    if pactl info >/dev/null 2>&1; then
        if ! pactl list short sinks | awk '{ print $2 }' | grep -qx circe; then
            pactl load-module module-null-sink sink_name=circe sink_properties=device.description=Circe rate=48000 channels=2 >/dev/null || true
        fi
        if [[ "$(pactl get-default-sink 2>/dev/null || true)" != circe ]]; then pactl set-default-sink circe || true; fi
    fi
    sleep 3
done
AUDIO

write_user_file "$UNITS/circe-audio.service" 600 <<EOF
[Unit]
Description=Circe headless audio output
Wants=$BACKEND.socket
After=$BACKEND.socket

[Service]
Type=simple
Environment=PULSE_SERVER=unix:%t/pulse/native
ExecStart="%h/.local/libexec/circe/start-audio"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
write_user_file "$UNITS/circe-desktop.service" 600 <<'UNIT'
[Unit]
Description=Circe private XFCE desktop
Wants=circe-audio.service
After=circe-audio.service

[Service]
Type=simple
ExecStart="%h/.local/libexec/circe/start-desktop"
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
KillMode=control-group

[Install]
WantedBy=default.target
UNIT
as_root loginctl enable-linger "$TARGET_USER"
as_root systemctl start "user@$TARGET_UID.service"
as_user systemctl --user daemon-reload
as_user systemctl --user enable --now "$BACKEND.socket"
as_user systemctl --user enable circe-audio.service circe-desktop.service
as_user systemctl --user restart circe-audio.service circe-desktop.service
READY=false
for ((attempt=0; attempt<30; attempt++)); do
    if report_status >/dev/null 2>&1; then READY=true; break; fi
    sleep 1
done
if ! $READY; then
    report_status || true
    printf '\nSee: journalctl --user -u circe-desktop -u circe-audio -n 60 --no-pager\n' >&2
    die 'Setup files are installed, but a service is not ready. Fix the reported issue, then rerun this script.'
fi
report_status
metadata() { curl -fsS --connect-timeout 1 --max-time 2 -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null || true; }
INSTANCE="$(metadata instance/name)"
ZONE="$(metadata instance/zone)"; ZONE="${ZONE##*/}"
PROJECT="$(metadata project/project-id)"
printf '\nIn Circe, choose Add a computer, then enter:\n'
if [[ -n "$INSTANCE" && -n "$ZONE" ]]; then
    printf '  Connection: Google Cloud\n  Instance: %s\n  Zone: %s\n  Project: %s\n  Use IAP: on\n' "$INSTANCE" "$ZONE" "$PROJECT"
else
    printf '  Connection: SSH\n  Destination: %s@%s (or your SSH-config alias)\n  SSH port: 22\n' "$TARGET_USER" "$(hostname -f 2>/dev/null || hostname)"
fi
printf '  VNC display: %s\n\nUse the VNC password shown on the first install. VNC stays on localhost:%s.\n' "$DISPLAY_NUMBER" "$VNC_PORT"
printf 'Audio source: circe.monitor (parec --device=circe.monitor --format=s16le --rate=48000 --channels=2 --raw).\n'
printf 'No VNC firewall rule or public VNC address is needed. Existing SSH/IAP access is required.\n'
# Password is JSON-safe base64, and is returned only when this run created it.
printf 'CIRCE_SETUP_RESULT {"display":%d,"password":%s,"audio":true}\n' "$DISPLAY_NUMBER" "$RESULT_PASSWORD"

}
main "$@"; exit $?
