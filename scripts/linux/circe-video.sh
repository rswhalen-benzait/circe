#!/usr/bin/env bash
# Run as the desktop account. Stream stdout is FLV; diagnostics belong on stderr.
main() {
# Tools installed by Circe without administrator access live in a private prefix.
# shellcheck disable=SC1091
[[ -r "$HOME/.config/circe/prefix.env" ]] && source "$HOME/.config/circe/prefix.env"
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
# Circe's desktop may be showing a session that was already open (Chrome Remote Desktop, RDP): capture that one.
if [[ -r "$RUNTIME/circe/desktop.env" && -r "$HOME/.config/circe/host.conf" ]] && grep -qx "DISPLAY_NUMBER=$DISPLAY_NUMBER" "$HOME/.config/circe/host.conf"; then
    SHARED="$(bash -c 'source "$1"; [[ "${CIRCE_SHARED_DISPLAY:-}" =~ ^[0-9]{1,2}$ ]] && printf "%s\n%s" "$CIRCE_SHARED_DISPLAY" "${CIRCE_SHARED_XAUTHORITY:-}"' _ "$RUNTIME/circe/desktop.env" 2>/dev/null || true)"
    if [[ -n "$SHARED" ]]; then
        DISPLAY_NUMBER="${SHARED%%$'\n'*}"
        if [[ "$SHARED" == *$'\n'?* ]]; then export XAUTHORITY="${SHARED#*$'\n'}"; fi
    fi
fi
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
