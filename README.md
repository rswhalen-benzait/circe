# Circe

A remote desktop for the Mac that should feel like sitting at the other machine.

Circe connects to another Mac running Circe (fastest: hardware HEVC, audio, low-latency UDP), or to
any Mac with built-in **Screen Sharing** turned on, or to any VNC server. No configuration, no port
forwarding on a LAN, and no pairing ritual after the first time.

## Using it

**Connect:** open Circe. Nearby Macs appear as cards (found through Bonjour). Click one.
The first time you connect, type the six-digit code shown on that Mac, or that Mac's account name
and password. After that, connections are instant.

You can also type an address: `studio.local`, `10.0.0.5`, `host:47800`, or `vnc://host` for a
VNC server.

**Linux and Google Cloud:** choose *Add a computer*. Save an SSH destination or Google Cloud
instance/zone (IAP is on by default), then connect with one click. *Set up & connect* installs a
private XFCE desktop and headless audio over SSH, saves the generated VNC password in Keychain,
and connects. SSH access must already work; automatic setup needs passwordless sudo.
See [Linux host setup](scripts/linux/README.md) for prerequisites, manual setup, and diagnostics.
Per-computer keyboard mapping, audio, and desktop resizing are in Settings → Computers.

On a Linux computer, ⌘ acts as Control by default, so ⌘C, ⌘V and ⌘T do what your fingers expect.
The remote desktop resizes to your window, sound plays through a second SSH channel, the clipboard
carries full Unicode text, and dropped connections (Wi-Fi blips, VM restarts) reconnect on their own.
Nothing is exposed to the internet: VNC listens on the VM's localhost only and travels inside SSH,
optionally through Google's Identity-Aware Proxy, so the VM needs no public IP or firewall hole.

**Smooth video on Linux:** VNC resends changed pixels as JPEG tiles, which can't keep up with video,
scrolling, or window drags at full resolution. On computers set up by Circe, the screen instead
arrives as an H.264 stream (FFmpeg on the VM: NVENC on an NVIDIA GPU, otherwise x264), decoded by
your Mac's hardware. VNC stays connected for keyboard, mouse, clipboard, cursor and resizing but
stops sending pixels. Video, audio and input each use their own SSH connection. If the network can't
keep up, Circe restarts the stream at a lower bitrate instead of falling behind. If video isn't
available (older setup, no FFmpeg), Circe uses VNC pixels and the toolbar says why; *Use smooth video*
turns it off per computer. Sound uses Opus (~128 kb/s) when the VM's audio helper is installed, raw
PCM otherwise. Frame rate starts conservative on small software-encoded VMs: 20 fps on 2 vCPUs,
30 fps on 4+, 60 fps with NVENC.

**While connected:**
- Every key goes to the remote Mac, including ⌘-Tab, ⌘-Space, ⌘-Q and Mission Control
  (grant Circe *Accessibility* on this Mac for the system-wide shortcuts).
- Hold **⌃⌥⌘** to use a shortcut on *this* Mac instead:
  ⌃⌥⌘F full screen · ⌃⌥⌘Esc release keyboard/mouse · ⌃⌥⌘S stats · ⌃⌥⌘D disconnect.
- Trackpad scrolling keeps its momentum and phases, so it feels native.
- The pointer is drawn locally with the remote cursor's shape, so it never lags.
- Clipboard syncs both ways (text, rich text, images). Your clipboard is only sent while the
  session window is focused.
- Drag files onto the session window to copy them to the remote Mac's Downloads folder.
- Sound from the remote Mac plays here.
- *Fit remote display to window* (Settings) resizes the remote Mac's display to your window and
  puts it back when you disconnect. Great for headless Mac minis.

**Disconnect:** close the window. That's it. If the network drops, Circe reconnects on its own
without asking again.

**Share this Mac:** click *Share this Mac*, allow Screen Recording and Accessibility when asked,
and you're done. Sharing starts automatically when you log in. Paired computers are listed in
Settings → Sharing, where you can forget them.

## What makes it fast

| | |
|---|---|
| Capture | ScreenCaptureKit at native Retina resolution, only when pixels change |
| Encode | VideoToolbox hardware HEVC, low-latency rate control, no B-frames, keyframes on demand |
| Transport | Encrypted UDP datagrams with adaptive XOR forward error correction; TCP fallback |
| Decode | Hardware decode straight into `AVSampleBufferDisplayLayer`, displayed immediately |
| Adaptation | Bitrate backs off on backlog or heavy loss and recovers; FEC strength follows loss |
| Audio | System audio captured with the screen, Opus at 10 ms packets, ~30 ms jitter buffer |
| Power | The remote display wakes on connect and stays awake during the session |

On this development Mac, loopback measured about 6 ms from capture to receive at 60 fps
(1080p HEVC), including at 5% simulated packet loss on the UDP path.

## Security

- Each device has a Curve25519 identity key stored only on that device.
- Every connection runs an ephemeral + static X25519 handshake bound to the transcript.
  All traffic (TCP and UDP) is encrypted with ChaCha20-Poly1305 and replay-protected.
- First contact is authenticated with the host's six-digit code or its macOS account
  password. Both sides then remember each other's key (trust on first use). A changed host
  key is refused.
- Failed attempts are rate-limited and capped at 5 per connection. Unauthenticated sessions are
  dropped after 2 minutes.
- Received files keep only their file name (no paths) and land in Downloads.
- VNC / Screen Sharing passwords are saved in the macOS Keychain.
- Linux / cloud connections run inside SSH (your keys or ssh-agent; host keys pinned on first use)
  or Google Cloud IAP. Circe refuses VNC logins that would send an account password unencrypted.

## Building

Requires macOS 14+ and Swift 6 (Command Line Tools are enough).

```sh
scripts/bundle.sh            # builds build/Circe.app (release, ad-hoc signed)
scripts/make-dmg.sh          # builds and verifies build/Circe.dmg
swift build                  # debug build of everything
.build/debug/circe-selftest  # protocol, crypto, FEC, Opus, ARD big-int and address tests
```

Disk image packaging also requires Python 3.10+. It installs pinned packaging tools into
`build/dmg-tools`, sets the Finder layout without UI scripting, and verifies the mounted app,
Applications link, background, and icon positions. Use `CIRCE_PYTHON=/path/to/python3` to select
Python, or `scripts/make-dmg.sh --skip-build` to package an existing release app.

`scripts/check-ui-model.sh` checks preferences and light/dark color contrast.
`scripts/check-onboarding.sh` briefly opens test windows to check first launch, relaunch, and
quiet-login reopening with isolated preferences. `scripts/preview-ui.sh` renders both appearances
into `build/previews/light` and `build/previews/dark`.

End-to-end without Screen Recording permission, using generated frames:

```sh
.build/debug/circe-cli host --open --synthetic --port 47811 &
.build/debug/circe-cli connect 127.0.0.1:47811 --seconds 5
# CIRCE_SIMULATE_LOSS=0.05 simulates packet loss · CIRCE_DISABLE_UDP=1 forces TCP
# CIRCE_SYNTHETIC_NOISE=1 makes frames large

python3 scripts/test/fake_rfb_server.py 5999 > /tmp/expect &   # VNC decoder fixture
.build/debug/circe-cli vnc 127.0.0.1:5999 $(head -1 /tmp/expect)

scripts/test/linux-e2e.sh    # Linux/cloud path: fake ssh + fake TigerVNC + fake PulseAudio + fake video/audio helpers
CIRCE_TEST_FFMPEG=/path/to/ffmpeg scripts/test/linux-e2e.sh   # + the real video helper and real x264
python3 scripts/test/check_linux_video.py; python3 scripts/test/check_linux_setup.py   # VM-side scripts
.build/debug/circe-cli vnc --gcloud INSTANCE --zone ZONE [--project P]   # a real GCP VM
.build/debug/circe-cli linux-setup --gcloud INSTANCE --zone ZONE --script scripts/linux/setup-circe-host.sh
```

## Layout

| Module | |
|---|---|
| `CirceCore` | Wire protocol, handshake/crypto, framed TCP, UDP datagrams + FEC, Opus, clipboard |
| `CirceHost` | Sharing service: capture, encode, input injection, cursor, display modes, file receive |
| `CirceClient` | Sessions: discovery, decode/display, input capture, audio playback, reconnect |
| `CirceVNC` | RFB client: VNC/ARD/VeNCrypt auth; Tight+JPEG/ZRLE/Hextile; continuous updates; resize; UTF-8 clipboard; SSH / IAP tunnels; H.264 video (FLV) and Opus/PCM audio over SSH; one-click Linux setup |
| `CirceUI`, `Circe` | SwiftUI app, design system, menu bar extra, settings |
| `circe-cli`, `circe-selftest` | Test harnesses |

## Not done yet

- Linux video is H.264 over TCP (SSH/IAP), not Circe's native UDP pipeline: there's no packet-loss
  recovery and no 4:4:4 colour, so fine coloured text is a little softer than on a Mac-to-Mac
  session. Google says IAP isn't meant for bulk transfer and may rate-limit it; a direct SSH route
  (public IP or VPN) is faster.
- The Linux path hasn't been run against a real GCP VM yet. Fixtures mimic ssh, TigerVNC,
  PulseAudio and the VM helpers. The real video helper and real x264 output were tested on macOS
  with a test pattern in place of X11 capture. Run `scripts/test/linux-e2e.sh`, then try a real VM.

- Microphone forwarding to the remote Mac (it needs a virtual audio device on the host).
- Connecting through NAT without a VPN (use Tailscale or similar for now).
- Logging in at the remote Mac's login window before any user has logged in (needs a
  privileged helper).
