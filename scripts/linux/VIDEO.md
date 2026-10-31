# Smooth Linux video

Circe can keep VNC for keyboard, pointer, clipboard, cursor shape, and desktop
resize while streaming H.264 video through a separate SSH/IAP connection. No
video listener or new cloud firewall rule is created. Enable **Use smooth video**
in a computer's connection preferences or Settings → Computers. The session pill
shows its actual video mode and measured stream FPS. Missing or failed video
falls back to VNC pixels.

Run host setup again to install FFmpeg and the helper on an existing Circe host.
Existing VNC passwords are preserved. A working NVIDIA driver and compatible
FFmpeg build are required for NVENC; setup does not install a GPU driver or add
external codec repositories. RHEL-family FFmpeg availability is best-effort.

## Wrapper interface

Installed path: `~/.local/libexec/circe/video`. Run as the desktop account.

```sh
~/.local/libexec/circe/video --check --display 1
~/.local/libexec/circe/video --display 1 > /tmp/circe-video.flv
```

The second command records until stopped; Circe normally runs the helper through
SSH and consumes stdout directly. Do not run it into an interactive terminal.

| Argument | Default / accepted values |
|---|---|
| `--display` | Configured Circe display, otherwise `1`; local `0…99`, `:1`, and `:1.0` accepted |
| `--encoder` | `auto`, `nvenc`, `x264` |
| `--fps` | `auto` or `1…120` |
| `--bitrate-kbps` | `auto` or `256…100000`; video bitrate ceiling |
| `--threads` | `auto` or `1…16`; software encoder threads |
| `--max-width`, `--max-height` | `0` retains native dimensions; explicit limits `128…8192` retain aspect and never upscale |
| `--check` | Verify tools, a real encoder probe, and X access; print configuration JSON instead of video |

The helper uses the service's private `circe-Xauthority` in `XDG_RUNTIME_DIR`
(normally `/run/user/UID`) when no explicit Xauthority is supplied. It captures
the root desktop with `x11grab`, without drawing a second cursor into the video.

Auto mode tries a real one-frame NVENC encode. An encoder merely appearing in
`ffmpeg -encoders` is insufficient. If NVENC cannot encode, x264 is selected before
any stream bytes. Explicit `--encoder nvenc` fails rather than silently switching.
An encoder failure during streaming ends that stream; the wrapper never appends
a second FLV header to an existing stream.

Initial resource budgets, to validate on the actual VM:

| Encoder / CPUs | Target FPS | Software threads | Bitrate ceiling |
|---|---:|---:|---:|
| x264, 1–2 vCPUs | 20 | 1 | 6 Mb/s |
| x264, 4 vCPUs | 30 | 2 | 8 Mb/s |
| x264, larger | 30 | Half the CPU count, capped at 4 | 8 Mb/s |
| Usable NVENC | 60 | 1 | 12 Mb/s |

These are starting limits, not performance guarantees. No default downscaling is
applied: reducing FPS preserves more text detail than shrinking the desktop.
Explicit FPS, bitrate, thread, and size overrides are supported. 4:2:0 still
softens fine colored text; low CRF cannot recover chroma discarded by subsampling.

## Wire format and diagnostics

Normal stdout is **video-only FLV carrying 8-bit 4:2:0 H.264/AVCC**. It includes
an AVC configuration record, length-prefixed NAL units, and complete length-framed
video tags. There are no B-frames, audio tags, shell logs, or JSON records on stream
stdout. Packets are flushed immediately; duration/filesize backpatching is disabled.
The maximum GOP is ten seconds; scene-cut IDRs are disabled for x264. Fresh
streams always start with an IDR. Reliable TCP delivery and fresh encoders after
resize or lag make frequent recovery frames unnecessary. The longer GOP reduces
the periodic text softening caused by tightly budgeted IDRs. VBV is roughly
250 ms (at least one frame); it is a rate-control budget, not an intentional
playback delay. Actual quality and queueing still need measurement on the VM.
Odd source dimensions receive minimal padding, with source and encoded dimensions
reported separately. RGB conversion uses a BT.709 matrix and explicit SDR color
tags, retaining the desktop's sRGB transfer curve.

Capture PTS derives from wallclock time and is normalized to stream start. It is
not a synthetic frame counter. Passthrough sync preserves capture stalls rather
than filling them with duplicate frames. Arrival-minus-capture drift can therefore
detect growing delay without requiring synchronized machine clocks. Normalization
also avoids placing full Unix-epoch milliseconds in FLV's narrow timestamp field.

The helper prints one selected-configuration line to stderr:

```text
CIRCE_VIDEO_CONFIG {"version":1,"codec":"h264","container":"flv","encoder":"x264","sourceWidth":1920,"sourceHeight":1080,"width":1920,"height":1080,"fps":30,"bitrateKbps":8000,"threads":2}
```

This reports the selected configuration, not successful rendering or achieved
FPS. Ordinary FFmpeg diagnostics follow on stderr. Errors have a separate
`CIRCE_VIDEO_ERROR {"code":N,"reason":"symbolic_reason"}` line; GPU fallback can
print a `CIRCE_VIDEO_WARNING` line. `--check` prints only unprefixed configuration
JSON on stdout on success, and no FLV.

| Exit code | Meaning |
|---:|---|
| 0 | Clean completion or handled cancellation |
| 64 | Invalid arguments / terminal output requested |
| 69 | Missing tool, capture/muxer support, or usable encoder |
| 77 | X display / authentication unavailable |
| 75 | Live capture or encoding failure |

SSH may return its own transport status. The client uses its cancellation state
to distinguish intentional teardown from an unexpected stream end. Desktop resize
requires a fresh helper process and decoder generation; VNC displays pixels during
the handoff. Input and video should use separate SSH connections, including when
the user's SSH configuration normally enables connection sharing.

## Development and verification

`circe-video.sh` is canonical. The installer embeds it alongside `circe-audio.sh`
so a single uploaded script can install everything without a public download URL.
After editing either helper:

```sh
python3 scripts/linux/embed-video-wrapper.py
python3 scripts/linux/embed-video-wrapper.py --check
shellcheck scripts/linux/circe-video.sh scripts/linux/circe-audio.sh scripts/linux/setup-circe-host.sh
python3 scripts/test/check_linux_video.py
python3 scripts/test/check_linux_setup.py
```

Bundling rejects a stale embedded helper. The setup fixture also checks that the
installed helper matches the source exactly. An optional real-encoder check uses
a local FFmpeg with libx264; a timed image pipe substitutes for Linux X capture:

```sh
CIRCE_TEST_FFMPEG=/path/to/ffmpeg python3 scripts/test/check_linux_video_real.py
```

It verifies complete FLV/AVCC frames, color conversion, no composition reordering,
and preserved capture-time gaps. It does not benchmark GCP CPUs, validate Linux
XShm behavior, or test a physical NVIDIA device. Actual host and WAN measurements
remain necessary before claiming 1080p60 performance.
