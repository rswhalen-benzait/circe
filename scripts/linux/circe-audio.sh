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
