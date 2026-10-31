# Circe — Plan of Record

Goal: a Mac remote desktop client that feels indistinguishable from sitting at the remote machine.
Zero-config connect, sub-frame latency on LAN, everything passed through (video, audio, input,
clipboard, files, cursor), effortless disconnect.

## What we take / what we drop
| From | Keep | Drop |
|---|---|---|
| macOS Screen Sharing | Bonjour discovery, smooth trackpad scroll w/ phases, clipboard sync, drag files, native feel | sluggish encoder, no audio, fuzzy text, modal clunky UI |
| TigerVNC | universal RFB compatibility (Linux/Win/Mac hosts) | ugly X11-ish UI, no HW decode, poor latency |
| Moonlight | HW HEVC encode/decode, UDP-style low latency, audio, local cursor feel, perf overlay | gaming-only, PIN pairing friction every host, no clipboard/files, needs Sunshine |

## Architecture (Swift Package, macOS 14+, one app: client + optional host)
- `CirceCore`   — wire protocol (framed messages), crypto (X25519 + ChaCha20-Poly1305, PIN pairing once, TOFU device keys in Keychain), transport (Network.framework; TCP control + low-latency video channel), Bonjour `_circe._tcp`.
- `CirceHost`   — ScreenCaptureKit capture (video + system audio), VideoToolbox HEVC low-latency encode (no B-frames, realtime), CGEvent input injection, cursor shape/position export, clipboard.
- `CirceClient` — session engine: AVSampleBufferDisplayLayer (HW decode, display-immediately), local cursor rendering, input capture (keyboard incl. Cmd-Tab etc. via event tap when focused, mouse absolute/relative, precise scroll w/ phases), audio playback w/ tiny jitter buffer, stats.
- `CirceVNC`    — RFB 3.8 client (Raw/CopyRect/Tight/ZRLE, VNC auth + Apple ARD auth type 30) exposed through the same session protocol so the UI doesn't care.
- `CirceUI`     — design system + SwiftUI views (launcher w/ discovered hosts, pairing, session window w/ auto-hide toolbar, prefs, host menu-bar extra, permissions onboarding).
- `Circe` app   — executable target; `scripts/bundle.sh` makes `build/Circe.app` (signed ad-hoc, icon, Info.plist w/ usage strings).
- `circe-cli`   — headless host/client for testing loopback end-to-end.

## Ownership (avoid edit collisions)
- Claude: Package.swift, CirceCore, CirceHost, CirceClient, circe-cli, tests for those.
- Codex:  CirceUI, Circe app target sources (Sources/Circe), app icon/assets, scripts/bundle.sh, CirceVNC.
- Contract between engine and UI: `Sources/CirceClient/PublicAPI.swift` + `Sources/CirceHost/PublicAPI.swift` (Claude owns; Codex requests changes via chat).

## Status (2026-10-30)
Done: loopback E2E (synthetic capture; real capture needs Screen Recording on the host), pairing (PIN/password, TOFU keys),
auto-reconnect, HEVC low-latency, UDP+adaptive FEC w/ TCP fallback, adaptive bitrate, Opus audio, clipboard (focus-gated),
local cursor, ⌘-key capture w/ ⌃⌥⌘ escape hatch, file drag-drop, dynamic resolution, video pause when hidden, VNC/ARD client
(verified vs real macOS Screen Sharing handshake + pixel-exact fixture), Bonjour for both, full SwiftUI app + icon + bundle.
Open: mic forwarding, NAT traversal, login-window access (privileged helper), 4:4:4 text mode, host-cursor-hidden sync.

## Milestones (ship each, then iterate)
1. Loopback E2E: host captures + encodes, client decodes + displays, input works. (localhost)
2. App UX: discovery, one-click connect, pairing once, fullscreen/window, auto-hide toolbar, clean disconnect.
3. Audio, clipboard, local cursor, Retina/HiDPI matching, dynamic resolution.
4. VNC/ARD compatibility path.
5. Perf: UDP video w/ FEC, adaptive bitrate, 120Hz/ProMotion, 4:4:4 text mode, stats overlay.
