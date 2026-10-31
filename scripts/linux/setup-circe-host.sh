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
    local failed=0 listeners address found=0 check_media="${1:-true}"
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
    if ! $check_media; then return "$failed"; fi
    if [[ -x "$LIBEXEC/video" ]]; then
        local video_config
        if video_config="$(as_user "$LIBEXEC/video" --check --display "$DISPLAY_NUMBER" 2>/dev/null)"; then printf '  Video: available %s\n' "$video_config"
        else printf '  Video: unavailable (VNC fallback is available)\n'; fi
    else printf '  Video: wrapper missing (VNC fallback is available)\n'; fi
    local audio_config
    if [[ -x "$LIBEXEC/audio" ]] && audio_config="$(as_user "$LIBEXEC/audio" --check 2>/dev/null)"; then
        printf '  Audio transport: Opus available %s\n' "$audio_config"
    else printf '  Audio transport: PCM fallback\n'; fi
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
    as_root env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install ffmpeg </dev/null \
        || printf 'FFmpeg installation failed; the desktop will use VNC pixels until video is available.\n' >&2
elif [[ "$FAMILY" == *rhel* || "$FAMILY" == *fedora* || "$FAMILY" == *rocky* || "$FAMILY" == *almalinux* ]]; then
    command -v dnf >/dev/null || die 'RHEL-family setup requires dnf and an enabled XFCE repository (usually EPEL/CRB).'
    if [[ "$FAMILY" != *fedora* ]]; then
        as_root dnf -y install epel-release </dev/null || printf 'Enable EPEL/CRB for your distribution if XFCE packages are unavailable.\n' >&2
    fi
    as_root dnf -y install tigervnc-server xfce4-session xfce4-panel xfce4-settings xfce4-terminal \
        xfdesktop xfwm4 Thunar dbus-x11 xorg-x11-xauth xdpyinfo pulseaudio-utils \
        openssl iproute curl ca-certificates dejavu-sans-fonts "$AUDIO_PACKAGE" </dev/null || die 'Package installation failed; check EPEL/CRB availability. No VNC firewall rule is needed.'
    as_root dnf -y install ffmpeg </dev/null || printf 'FFmpeg with libx264 or NVENC is optional; enable a suitable codec repository yourself if required. VNC remains available.\n' >&2
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

# BEGIN GENERATED CIRCE VIDEO WRAPPER
write_user_file "$LIBEXEC/video" 700 <<'CIRCE_VIDEO_WRAPPER'
#!/usr/bin/env bash
# Run as the desktop account. Stream stdout is FLV; diagnostics belong on stderr.
main() {
set -euo pipefail
export LC_ALL=C
umask 077
failure() {
    printf 'CIRCE_VIDEO_ERROR {"code":%d,"reason":"%s"}\n' "$1" "$2" >&2
    printf 'Circe video: %s\n' "$3" >&2
    exit "$1"
}
usage() {
    cat <<'HELP'
Usage: video [--display 1] [--encoder auto|nvenc|x264] [--fps auto|1..120]
             [--bitrate-kbps auto|256..100000] [--threads auto|1..16]
             [--max-width 0..8192] [--max-height 0..8192] [--check]
Default stdout is video-only H.264/AVCC in FLV. --check prints JSON instead.
Native dimensions are retained unless a maximum size is explicitly supplied.
HELP
}
DISPLAY_NUMBER=
ENCODER=auto
FPS=auto
BITRATE=auto
THREADS=auto
MAX_WIDTH=0
MAX_HEIGHT=0
CHECK=false
while (($#)); do
    case "$1" in
        --display|--encoder|--fps|--bitrate-kbps|--threads|--max-width|--max-height)
            (($# >= 2)) || failure 64 invalid_arguments "Missing value for $1."
            case "$1" in
                --display) DISPLAY_NUMBER="${2#:}"; DISPLAY_NUMBER="${DISPLAY_NUMBER%.0}" ;;
                --encoder) ENCODER="$2" ;;
                --fps) FPS="$2" ;;
                --bitrate-kbps) BITRATE="$2" ;;
                --threads) THREADS="$2" ;;
                --max-width) MAX_WIDTH="$2" ;;
                --max-height) MAX_HEIGHT="$2" ;;
            esac
            shift 2 ;;
        --check) CHECK=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) failure 64 invalid_arguments "Unknown option: $1." ;;
    esac
done
integer() { [[ "$1" =~ ^[0-9]{1,6}$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }
if [[ -z "$DISPLAY_NUMBER" && -r "$HOME/.config/circe/host.conf" ]]; then
    DISPLAY_NUMBER="$(awk -F= '/^DISPLAY_NUMBER=[0-9]+$/ { print $2; exit }' "$HOME/.config/circe/host.conf")"
fi
DISPLAY_NUMBER="${DISPLAY_NUMBER:-1}"
integer "$DISPLAY_NUMBER" 0 99 || failure 64 invalid_arguments 'Display must be a local X11 display from 0 to 99.'
DISPLAY_NUMBER=$((10#$DISPLAY_NUMBER))
case "$ENCODER" in auto|nvenc|x264) ;; *) failure 64 invalid_arguments 'Encoder must be auto, nvenc, or x264.' ;; esac
[[ "$FPS" == auto ]] || integer "$FPS" 1 120 || failure 64 invalid_arguments 'FPS must be auto or from 1 to 120.'
[[ "$BITRATE" == auto ]] || integer "$BITRATE" 256 100000 || failure 64 invalid_arguments 'Bitrate must be auto or from 256 to 100000 kb/s.'
[[ "$THREADS" == auto ]] || integer "$THREADS" 1 16 || failure 64 invalid_arguments 'Threads must be auto or from 1 to 16.'
if ! integer "$MAX_WIDTH" 0 8192 || ! integer "$MAX_HEIGHT" 0 8192; then failure 64 invalid_arguments 'Maximum dimensions must be from 0 to 8192.'; fi
MAX_WIDTH=$((10#$MAX_WIDTH)); MAX_HEIGHT=$((10#$MAX_HEIGHT))
[[ "$MAX_WIDTH" == 0 ]] || ((MAX_WIDTH >= 128)) || failure 64 invalid_arguments 'A nonzero maximum width must be at least 128.'
[[ "$MAX_HEIGHT" == 0 ]] || ((MAX_HEIGHT >= 128)) || failure 64 invalid_arguments 'A nonzero maximum height must be at least 128.'
[[ "$(uname -s)" == Linux ]] || failure 69 unsupported_platform 'Run this wrapper on the Linux desktop host.'
for tool in ffmpeg xdpyinfo timeout; do command -v "$tool" >/dev/null || failure 69 missing_tool "Missing $tool. Run Circe host setup again."; done
if ! $CHECK && [[ -t 1 ]]; then failure 64 terminal_output 'FLV output must go to Circe or a file, not an interactive terminal.'; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/circe-video.XXXXXX")"
CHILD_PID=
# Invoked by EXIT and signal traps.
# shellcheck disable=SC2329
cleanup() {
    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$CHILD_PID" ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        local attempt
        for ((attempt=0; attempt<10; attempt++)); do
            kill -0 "$CHILD_PID" 2>/dev/null || break
            sleep 0.1
        done
        # FFmpeg can stall during graceful shutdown. This stream is being
        # discarded; do not wait indefinitely for a container trailer.
        if kill -0 "$CHILD_PID" 2>/dev/null; then kill -KILL "$CHILD_PID" 2>/dev/null || true; fi
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ -z "${XAUTHORITY:-}" && -r "$RUNTIME/circe-Xauthority" ]]; then export XAUTHORITY="$RUNTIME/circe-Xauthority"; fi
X_DISPLAY=":$DISPLAY_NUMBER.0"
if ! INFO="$(timeout 5 xdpyinfo -display "$X_DISPLAY" 2>"$WORK/display-error")"; then
    cat "$WORK/display-error" >&2
    failure 77 display_unavailable 'Cannot access the virtual desktop. Check its display number and Xauthority, or rerun host setup.'
fi
read -r SOURCE_WIDTH SOURCE_HEIGHT < <(awk '/^[[:space:]]*dimensions: / { split($2, a, "x"); print a[1], a[2]; exit }' <<< "$INFO") || failure 77 display_unavailable 'Cannot determine the X11 desktop dimensions.'
if ! integer "$SOURCE_WIDTH" 1 16384 || ! integer "$SOURCE_HEIGHT" 1 16384; then failure 77 display_unavailable 'Unsupported X11 desktop dimensions.'; fi
SOURCE_WIDTH=$((10#$SOURCE_WIDTH)); SOURCE_HEIGHT=$((10#$SOURCE_HEIGHT))
DEVICES="$(ffmpeg -hide_banner -devices 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list capture devices.'
awk '$2 == "x11grab" { found=1 } END { exit !found }' <<< "$DEVICES" || failure 69 missing_capture 'This FFmpeg build lacks x11grab.'
MUXERS="$(ffmpeg -hide_banner -muxers 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list muxers.'
awk '$2 == "flv" { found=1 } END { exit !found }' <<< "$MUXERS" || failure 69 missing_muxer 'This FFmpeg build lacks FLV output.'
ENCODERS="$(ffmpeg -hide_banner -encoders 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list encoders.'
has_encoder() { awk -v name="$1" '$2 == name { found=1 } END { exit !found }' <<< "$ENCODERS"; }
# Encoder presence alone is insufficient: drivers, device access, and NVENC sessions can fail.
probe() {
    timeout 5 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i color=c=black:s=128x128:r=1 \
        -frames:v 1 -pix_fmt yuv420p -c:v "$1" "${@:2}" -profile:v high -bf 0 -f null - \
        >/dev/null 2>"$WORK/probe-error"
}
REQUESTED_ENCODER="$ENCODER"
if [[ "$ENCODER" == auto || "$ENCODER" == nvenc ]]; then
    if has_encoder h264_nvenc && probe h264_nvenc -preset p1 -tune ull -rc-lookahead 0 -zerolatency 1; then
        ENCODER=nvenc
    elif [[ "$REQUESTED_ENCODER" == nvenc ]]; then
        cat "$WORK/probe-error" >&2 2>/dev/null || true
        failure 69 encoder_unavailable 'NVENC could not encode a frame. Check the NVIDIA driver and FFmpeg build.'
    else
        printf 'CIRCE_VIDEO_WARNING NVENC unavailable; trying software x264.\n' >&2
        ENCODER=x264
    fi
fi
if [[ "$ENCODER" == x264 ]]; then
    has_encoder libx264 || failure 69 encoder_unavailable 'This FFmpeg build has no libx264 encoder and NVENC is unavailable.'
    probe libx264 -preset ultrafast -tune zerolatency || { cat "$WORK/probe-error" >&2; failure 69 encoder_unavailable 'x264 could not encode a frame.'; }
fi
CPUS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf 2)"
integer "$CPUS" 1 4096 || CPUS=2
CPUS=$((10#$CPUS))
if [[ "$FPS" == auto ]]; then
    if [[ "$ENCODER" == nvenc ]]; then FPS=60; elif ((CPUS <= 2)); then FPS=20; else FPS=30; fi
else FPS=$((10#$FPS)); fi
if [[ "$BITRATE" == auto ]]; then
    if [[ "$ENCODER" == nvenc ]]; then BITRATE=12000; elif ((CPUS <= 2)); then BITRATE=6000; else BITRATE=8000; fi
else BITRATE=$((10#$BITRATE)); fi
if [[ "$THREADS" == auto ]]; then
    if [[ "$ENCODER" == nvenc ]]; then THREADS=1
    else THREADS=$((CPUS / 2)); ((THREADS >= 1)) || THREADS=1; ((THREADS <= 4)) || THREADS=4; fi
else THREADS=$((10#$THREADS)); fi

# Preserve native text pixels by default. Explicit size limits retain aspect and never upscale.
WIDTH="$SOURCE_WIDTH"; HEIGHT="$SOURCE_HEIGHT"
if ((MAX_WIDTH > 0 && WIDTH > MAX_WIDTH)); then HEIGHT=$((HEIGHT * MAX_WIDTH / WIDTH)); WIDTH="$MAX_WIDTH"; fi
if ((MAX_HEIGHT > 0 && HEIGHT > MAX_HEIGHT)); then WIDTH=$((WIDTH * MAX_HEIGHT / HEIGHT)); HEIGHT="$MAX_HEIGHT"; fi
((WIDTH > 0 && HEIGHT > 0)) || failure 64 invalid_arguments 'Requested size is too small for this desktop aspect ratio.'
FILTER=""
if ((WIDTH != SOURCE_WIDTH || HEIGHT != SOURCE_HEIGHT)); then FILTER="scale=$WIDTH:$HEIGHT:flags=fast_bilinear,"; fi
WIDTH=$(((WIDTH + 1) / 2 * 2)); HEIGHT=$(((HEIGHT + 1) / 2 * 2))
FILTER+="format=bgr0,pad=ceil(iw/2)*2:ceil(ih/2)*2,scale=in_range=full:out_range=limited:out_color_matrix=bt709,format=yuv420p"
GOP=$((FPS * 10)) # TCP preserves frames; avoid a visible IDR quality pulse every second
VBV=$((BITRATE / 4)) # 250ms allows a more detailed IDR without burning idle bandwidth
MIN_VBV=$(((BITRATE + FPS - 1) / FPS))
((VBV >= MIN_VBV)) || VBV="$MIN_VBV" # never smaller than one frame at an explicit low FPS
CONFIG="{\"version\":1,\"codec\":\"h264\",\"container\":\"flv\",\"encoder\":\"$ENCODER\",\"sourceWidth\":$SOURCE_WIDTH,\"sourceHeight\":$SOURCE_HEIGHT,\"width\":$WIDTH,\"height\":$HEIGHT,\"fps\":$FPS,\"bitrateKbps\":$BITRATE,\"threads\":$THREADS}"
if $CHECK; then printf '%s\n' "$CONFIG"; exit 0; fi
printf 'CIRCE_VIDEO_CONFIG %s\n' "$CONFIG" >&2
ENCODER_ARGS=()
if [[ "$ENCODER" == nvenc ]]; then
    ENCODER_ARGS=(-c:v h264_nvenc -preset p1 -tune ull -rc vbr -cq 18 -b:v "${BITRATE}k" -rc-lookahead 0 -zerolatency 1 -delay 0)
else
    ENCODER_ARGS=(-c:v libx264 -preset ultrafast -tune zerolatency -crf 18 -threads "$THREADS"
        -x264-params "keyint=$GOP:min-keyint=$FPS:scenecut=0:rc-lookahead=0:sync-lookahead=0")
fi
# No -re: x11grab is paced at capture. One queued input frame, no B-frames, no audio or stdout logs.
# A fresh FFmpeg process is required on resize or encoder failure; never concatenate FLV streams.
ffmpeg -nostdin -hide_banner -loglevel warning -copyts -start_at_zero -thread_queue_size 1 \
    -use_wallclock_as_timestamps 1 -f x11grab -draw_mouse 0 \
    -framerate "$FPS" -video_size "${SOURCE_WIDTH}x${SOURCE_HEIGHT}" -i "$X_DISPLAY" \
    -map 0:v:0 -an -sn -dn -filter_threads 1 -vf "$FILTER" "${ENCODER_ARGS[@]}" \
    -profile:v high -pix_fmt yuv420p -bf 0 -g "$GOP" -maxrate "${BITRATE}k" -bufsize "${VBV}k" \
    -color_primaries bt709 -color_trc iec61966-2-1 -colorspace bt709 -color_range tv \
    -vsync 0 -f flv -flvflags no_duration_filesize -flush_packets 1 pipe:1 </dev/null &
CHILD_PID=$!
if wait "$CHILD_PID"; then STATUS=0; else STATUS=$?; fi
CHILD_PID=
((STATUS == 0)) || failure 75 encoder_failed "Capture/encoding stopped (FFmpeg status $STATUS)."
}
main "$@"; exit $?
CIRCE_VIDEO_WRAPPER
# END GENERATED CIRCE VIDEO WRAPPER

# BEGIN GENERATED CIRCE AUDIO WRAPPER
write_user_file "$LIBEXEC/audio" 700 <<'CIRCE_AUDIO_WRAPPER'
#!/usr/bin/env bash
# Run as the desktop account. Ogg/Opus on stdout; all diagnostics on stderr.
main() {
set -euo pipefail
export LC_ALL=C
umask 077
failure() {
    printf 'CIRCE_AUDIO_ERROR {"code":%d,"reason":"%s"}\n' "$1" "$2" >&2
    printf 'Circe audio: %s\n' "$3" >&2
    exit "$1"
}
usage() {
    cat <<'HELP'
Usage: audio [--bitrate-kbps 32..256] [--check]
Default stdout is Ogg/Opus, 48 kHz stereo, 10 ms packets, 128 kb/s.
--check verifies capabilities and PulseAudio access, then prints JSON instead.
HELP
}
BITRATE=128
CHECK=false
while (($#)); do
    case "$1" in
        --bitrate-kbps)
            (($# >= 2)) || failure 64 invalid_arguments 'Missing bitrate.'
            BITRATE="$2"; shift 2 ;;
        --check) CHECK=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) failure 64 invalid_arguments "Unknown option: $1." ;;
    esac
done
if [[ ! "$BITRATE" =~ ^[0-9]{1,3}$ ]] || ! ((10#$BITRATE >= 32 && 10#$BITRATE <= 256)); then
    failure 64 invalid_arguments 'Bitrate must be from 32 to 256 kb/s.'
fi
BITRATE=$((10#$BITRATE))
[[ "$(uname -s)" == Linux ]] || failure 69 unsupported_platform 'Run this helper on the Linux desktop host.'
for tool in ffmpeg pactl timeout; do command -v "$tool" >/dev/null || failure 69 missing_tool "Missing $tool; using PCM audio instead."; done
if ! $CHECK && [[ -t 1 ]]; then failure 64 terminal_output 'Ogg output must go to Circe or a file, not an interactive terminal.'; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/circe-audio.XXXXXX")"
CHILD_PID=
# Invoked by EXIT and signal traps.
# shellcheck disable=SC2329
cleanup() {
    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$CHILD_PID" ]]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        local attempt
        for ((attempt=0; attempt<10; attempt++)); do
            kill -0 "$CHILD_PID" 2>/dev/null || break
            sleep 0.1
        done
        # Cancellation discards the stream; stalled graceful shutdown must
        # not retain an encoder or prevent an audio channel restart.
        if kill -0 "$CHILD_PID" 2>/dev/null; then kill -KILL "$CHILD_PID" 2>/dev/null || true; fi
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export PULSE_SERVER="${PULSE_SERVER:-unix:$XDG_RUNTIME_DIR/pulse/native}"
# Every exit 69 is before the live encoder starts and before any stdout bytes.
# The caller can safely fall through to parec on exactly this status.
if ! timeout 5 pactl info > /dev/null 2>"$WORK/pulse-error"; then
    cat "$WORK/pulse-error" >&2
    failure 69 audio_unavailable 'Cannot reach the PulseAudio/PipeWire-pulse server for this account.'
fi
DEVICES="$(ffmpeg -hide_banner -devices 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list capture devices.'
awk '$2 == "pulse" { found=1 } END { exit !found }' <<< "$DEVICES" || failure 69 missing_capture 'This FFmpeg build lacks PulseAudio input; using PCM instead.'
MUXERS="$(ffmpeg -hide_banner -muxers 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list muxers.'
awk '$2 == "ogg" { found=1 } END { exit !found }' <<< "$MUXERS" || failure 69 missing_muxer 'This FFmpeg build lacks Ogg output; using PCM instead.'
ENCODERS="$(ffmpeg -hide_banner -encoders 2>"$WORK/tools-error")" || failure 69 unusable_ffmpeg 'FFmpeg cannot list encoders.'
awk '$2 == "libopus" { found=1 } END { exit !found }' <<< "$ENCODERS" || failure 69 missing_encoder 'This FFmpeg build lacks libopus; using PCM instead.'
OPUS_ARGS=(-c:a libopus -application lowdelay -frame_duration 10 -b:a "${BITRATE}k"
    -vbr constrained -compression_level 5 -ar 48000 -ac 2 -mapping_family 0 -threads 1)
if ! timeout 5 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i anullsrc=r=48000:cl=stereo \
    -frames:a 1 "${OPUS_ARGS[@]}" -f ogg -page_duration 20000 -flush_packets 1 pipe:1 \
    > /dev/null 2>"$WORK/probe-error"; then
    cat "$WORK/probe-error" >&2
    failure 69 encoder_unavailable 'Opus could not encode a packet; using PCM instead.'
fi
CONFIG="{\"version\":1,\"codec\":\"opus\",\"container\":\"ogg\",\"sampleRate\":48000,\"channels\":2,\"frameSamples\":480,\"frameDurationMs\":10,\"pageDurationMs\":20,\"bitrateKbps\":$BITRATE}"
if $CHECK; then printf '%s\n' "$CONFIG"; exit 0; fi
printf 'CIRCE_AUDIO_CONFIG %s\n' "$CONFIG" >&2
# 1920 bytes is 10 ms of s16 stereo. The audio server may negotiate a larger
# fragment; this is a request, not an end-to-end latency guarantee.
ffmpeg -nostdin -hide_banner -loglevel warning -thread_queue_size 2 \
    -probesize 32 -analyzeduration 1 -f pulse -sample_rate 48000 -channels 2 -fragment_size 1920 -i @DEFAULT_MONITOR@ \
    -map 0:a:0 -vn -sn -dn "${OPUS_ARGS[@]}" \
    -f ogg -page_duration 20000 -flush_packets 1 pipe:1 </dev/null &
CHILD_PID=$!
if wait "$CHILD_PID"; then STATUS=0; else STATUS=$?; fi
CHILD_PID=
((STATUS == 0)) || failure 75 encoder_failed "Audio capture/encoding stopped (FFmpeg status $STATUS)."
}
main "$@"; exit $?
CIRCE_AUDIO_WRAPPER
# END GENERATED CIRCE AUDIO WRAPPER

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
    if report_status false >/dev/null 2>&1; then READY=true; break; fi
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
