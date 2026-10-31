# Compressed Linux audio

Circe records the remote account's default output monitor over its own SSH/IAP
connection. The installed `~/.local/libexec/circe/audio` helper sends Ogg/Opus
instead of 1.536 Mb/s raw PCM. If the helper is missing or exits 69, the client
uses `parec` as before. Video and audio remain separate streams.

Run host setup again to install the helper. No additional package is needed
beyond FFmpeg with PulseAudio input, libopus, and Ogg support. Existing
PulseAudio or PipeWire-pulse setup is retained.

```sh
~/.local/libexec/circe/audio --check
~/.local/libexec/circe/audio > /tmp/circe-audio.ogg
```

Stop recording with Control-C. Default stream stdout is **only Ogg/Opus**:

- 48 kHz stereo, channel mapping family 0.
- Exactly 10 ms / 480-sample Opus packets, matching the client decoder contract.
- `lowdelay` application, 128 kb/s constrained VBR, complexity 5, one encoder thread.
- Preferred Ogg page duration 20 ms and immediate output flushing. Pages carry
  OpusHead, OpusTags, then Opus audio packets. Container and SSH overhead are
  additional to the encoder bitrate.
- Capture uses `@DEFAULT_MONITOR@`, preserving the same source as PCM fallback.
  The helper honors an existing `PULSE_SERVER`; otherwise it uses the account's
  `XDG_RUNTIME_DIR/pulse/native` socket. The requested capture fragment is 10 ms;
  actual fragments and total latency depend on the audio server and client.

Optional `--bitrate-kbps 32…256` changes the target bitrate. Packet duration,
sample rate, and channel layout remain fixed. `--check` prints configuration
JSON instead of audio after verifying the audio server, FFmpeg capabilities,
and a real Opus encode/mux probe. It does not start live monitor capture.

Normal streaming prints selected configuration to **stderr** before FFmpeg:

```text
CIRCE_AUDIO_CONFIG {"version":1,"codec":"opus","container":"ogg","sampleRate":48000,"channels":2,"frameSamples":480,"frameDurationMs":10,"pageDurationMs":20,"bitrateKbps":128}
```

Errors use `CIRCE_AUDIO_ERROR {"code":N,"reason":"symbolic_reason"}` plus a
human-readable stderr message. Exit codes:

| Code | Meaning |
|---:|---|
| 0 | Clean completion or handled cancellation |
| 64 | Invalid arguments or binary output requested on a terminal |
| 69 | Unavailable tools, audio server, encoder, or muxer; **zero stdout bytes** |
| 75 | Live capture/encoding failure; the stream may already contain Ogg bytes |

Exit 69 is reserved for preflight failures. It is safe for the calling SSH
command to start `parec` on that status. After live encoding begins, the helper
never returns 69, appends PCM, or restarts a container in place. The client must
start a fresh channel for recovery. Cancellation sends TERM, waits about one
second, then sends KILL if needed and reaps the owned encoder process.

The self-contained installer embeds this helper alongside the video helper.
`embed-video-wrapper.py` updates both payloads; bundling rejects stale copies.

```sh
python3 scripts/linux/embed-video-wrapper.py --check
shellcheck scripts/linux/circe-audio.sh scripts/linux/setup-circe-host.sh
python3 scripts/test/check_linux_audio.py
CIRCE_TEST_FFMPEG=/path/to/ffmpeg python3 scripts/test/check_linux_audio_real.py
```

The real-encoder fixture feeds paced PCM in place of PulseAudio and verifies
packet duration, channel configuration, incremental page delivery, and decoded
duration. It cannot establish real Linux capture latency, WAN jitter, or A/V
sync. Separate channels and small packets do not by themselves synchronize
audio and video.

FFmpeg defines [Opus options](https://github.com/FFmpeg/FFmpeg/blob/n4.4/libavcodec/libopusenc.c)
and [Ogg page duration](https://github.com/FFmpeg/FFmpeg/blob/n4.4/libavformat/oggenc.c).
