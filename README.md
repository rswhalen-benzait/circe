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
```

## Layout

| Module | |
|---|---|
| `CirceCore` | Wire protocol, handshake/crypto, framed TCP, UDP datagrams + FEC, Opus, clipboard |
| `CirceHost` | Sharing service: capture, encode, input injection, cursor, display modes, file receive |
| `CirceClient` | Sessions: discovery, decode/display, input capture, audio playback, reconnect |
| `CirceVNC` | RFB 3.8 client: VNC + Apple Remote Desktop auth, ZRLE/Hextile/CopyRect/Raw |
| `CirceUI`, `Circe` | SwiftUI app, design system, menu bar extra, settings |
| `circe-cli`, `circe-selftest` | Test harnesses |

## Not done yet

- Microphone forwarding to the remote Mac (it needs a virtual audio device on the host).
- Connecting through NAT without a VPN (use Tailscale or similar for now).
- Logging in at the remote Mac's login window before any user has logged in (needs a
  privileged helper).
