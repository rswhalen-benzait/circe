#!/bin/bash
# End-to-end checks for Circe's Linux / cloud path without a real VM:
# fake ssh (maps -W onto nc) + fake TigerVNC (VeNCrypt, Tight/JPEG, resize, UTF-8 clipboard) + fake parec + fake H.264 video helper.
set -u
cd "$(dirname "$0")/../.." || exit 1
swift build --product circe-cli >/dev/null 2>&1 || { echo "build failed"; exit 1; }
CLI=.build/debug/circe-cli
TMP=$(mktemp -d); trap 'pkill -f fake_tigervnc.py; rm -rf "$TMP" "${TMPDIR:-/tmp}"/circe-fake-parec-$$ "${TMPDIR:-/tmp}"/circe-fake-video-$$' EXIT
export CIRCE_SSH_PATH=$PWD/scripts/test/fake-ssh
python3 - "$TMP/blue.png" <<'PY'
import struct, sys, zlib
w = h = 32
raw = b"".join(b"\0" + b"\x00\x00\xff" * w for _ in range(h))
c = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b""))
PY
swift build --product circe-selftest >/dev/null 2>&1 && .build/debug/circe-selftest --write-test-ogg "$TMP/tone.ogg" || { echo "ogg fixture failed"; exit 1; }
swift scripts/test/make-flv.swift "$TMP/desk.flv" 120 320x240 >/dev/null || { echo "make-flv failed"; exit 1; }
sips -s format jpeg -s formatOptions 90 "$TMP/blue.png" --out "$TMP/blue.jpg" >/dev/null
python3 scripts/test/fake_tigervnc.py 5921 plain "$TMP/blue.jpg" > "$TMP/plain.out" 2>/dev/null &
python3 scripts/test/fake_tigervnc.py 5922 vncauth "$TMP/blue.jpg" > "$TMP/vnc.out" 2>/dev/null &
disown -a
sleep 1
pass=0; fail=0
check() { local name="$1" want="$2"; shift 2; out=$("$@" 2>&1 | tail -1)
  if [[ "$out" == *"$want"* ]]; then pass=$((pass+1)); echo "ok   $name"; else fail=$((fail+1)); echo "FAIL $name: $out"; fi; }
check "ssh + VeNCrypt Plain + Tight + resize + clipboard + audio" "mismatches=0" \
  $CLI vnc --ssh t@vm --display 21 --user circe --password secret --seconds 2 --tolerance 6 --resize 1024x640 \
  --expect-clipboard "Grüße from Linux ✓" --expect-audio $(head -1 "$TMP/plain.out")
check "ssh + VeNCrypt VncAuth" "mismatches=0" \
  $CLI vnc --ssh t@vm --display 22 --password x --seconds 1 --tolerance 6 --expect-audio $(head -1 "$TMP/vnc.out")
check "continuous updates stream without requests (fps>10)" "mismatches=0" \
  $CLI vnc --ssh t@vm --display 22 --password x --seconds 3 --min-fps 10
check "audio recovers after the remote audio stream ends" "mismatches=0" \
  env FAKE_PAREC_EXIT_AFTER=1 FAKE_PAREC_RUN=$$ $CLI vnc --ssh t@vm --display 22 --password x --seconds 5 --expect-audio
check "H.264 video replaces VNC pixels (60 fps, VNC quiet), survives a resize" "mismatches=0" \
  env FAKE_VIDEO_FLV="$TMP/desk.flv" $CLI vnc --ssh t@vm --display 22 --password x --seconds 3 --expect-video --min-fps 45 --expect-audio --resize 1024x640
check "no video helper on the VM falls back to VNC" "VNC · Tight" \
  $CLI vnc --ssh t@vm --display 22 --password x --seconds 2 --min-fps 10
check "video recovers after the stream dies" "mismatches=0" \
  env FAKE_VIDEO_FLV="$TMP/desk.flv" FAKE_VIDEO_EXIT_AFTER=1 FAKE_VIDEO_RUN=$$ $CLI vnc --ssh t@vm --display 22 --password x --seconds 5 --expect-video
check "video that falls behind restarts at a lower bitrate" "videoLimit=3600 fpsLimit=0 mismatches=0" \
  env FAKE_VIDEO_FLV="$TMP/desk.flv" FAKE_VIDEO_LAG=1 $CLI vnc --ssh t@vm --display 22 --password x --seconds 6 --expect-video
check "video still behind at lower bitrate also lowers the frame rate" "videoLimit=2160 fpsLimit=40 mismatches=0" \
  env FAKE_VIDEO_FLV="$TMP/desk.flv" FAKE_VIDEO_LAG=2 $CLI vnc --ssh t@vm --display 22 --password x --seconds 10 --expect-video
check "a shared session's clipboard arrives through Circe's clipboard helper" "mismatches=0" \
  env FAKE_CLIPBOARD_TEXT="Shared session ✓ $$" $CLI vnc --ssh t@vm --display 22 --password x --seconds 2 --expect-clipboard "Shared session ✓ $$"
check "Opus audio from the audio helper" "mismatches=0" \
  env FAKE_AUDIO_OGG="$TMP/tone.ogg" $CLI vnc --ssh t@vm --display 22 --password x --seconds 2 --expect-audio --expect-audio-encoding opus
check "no audio helper falls back to raw PCM (parec)" "mismatches=0" \
  $CLI vnc --ssh t@vm --display 22 --password x --seconds 2 --expect-audio --expect-audio-encoding pcm16
check "Plain auth refused without a tunnel" "unencrypted" $CLI vnc 127.0.0.1:5921
check "wrong password is reported" "Authentication failed" $CLI vnc --ssh t@vm --display 21 --user circe --password nope
check "ssh key refused is explained" "SSH refused the login" env FAKE_SSH_FAIL="Permission denied (publickey)." $CLI vnc --ssh t@vm --display 21
check "missing VNC server is explained" "no VNC server is running" $CLI vnc --ssh t@vm --display 49
# Optional: the REAL video helper + real x264 (test pattern instead of X11). CIRCE_TEST_FFMPEG=/path/to/ffmpeg
if [[ -n "${CIRCE_TEST_FFMPEG:-}" ]]; then
  check "real helper + x264 → client (auto 30 fps on 4 CPUs)" "mismatches=0" \
    env FAKE_VIDEO_REAL=1 XDG_RUNTIME_DIR="$TMP" $CLI vnc --ssh t@vm --display 22 --password x --seconds 4 --expect-video --min-fps 25
  ( PATH="$PWD/scripts/test/realvideo:$PATH" CIRCE_TEST_PATTERN="color=c=0x2040E0" XDG_RUNTIME_DIR="$TMP" \
      bash scripts/linux/circe-video.sh --display 1 > "$TMP/real.flv" 2>/dev/null & p=$!; sleep 2; pkill -TERM -P $p; kill $p ) 2>/dev/null
  check "real x264 stream decodes in VideoToolbox with correct colour" "centre=1F3EDD" \
    .build/debug/circe-selftest --decode-flv "$TMP/real.flv" 1280x800
  # Same Opus settings as scripts/linux/circe-audio.sh, from a mono 440 Hz sine (−3 dB when upmixed).
  "$CIRCE_TEST_FFMPEG" -nostdin -hide_banner -loglevel error -f lavfi -i sine=frequency=440:sample_rate=48000 -t 2 -ac 2 \
    -c:a libopus -application lowdelay -frame_duration 10 -b:a 128k -vbr constrained -compression_level 5 -ar 48000 \
    -mapping_family 0 -f ogg -page_duration 20000 -flush_packets 1 -y "$TMP/real.ogg"
  check "real libopus Ogg decodes (10 ms packets, correct level)" "rms=0.06" .build/debug/circe-selftest --decode-ogg "$TMP/real.ogg"
  check "real libopus Ogg plays through the client" "mismatches=0" \
    env FAKE_AUDIO_OGG="$TMP/real.ogg" $CLI vnc --ssh t@vm --display 22 --password x --seconds 2 --expect-audio --expect-audio-encoding opus
fi
echo; echo "$pass passed, $fail failed"; exit $fail
