# Nubo

Nubo is a native macOS/iPadOS remote-desktop system focused on low latency, precise input, and predictable behavior on a local network. `NuboMac` is the host and `NuboiPad` is the client. Bonjour is only a discovery mechanism: manual IP and hostname endpoints use the same session architecture, so a future Tailscale hostname does not require changes to video, audio, input, pairing, or session logic.

> Current milestone: usable LAN MVP. Discovery/manual connection, mutually confirmed pairing, encrypted control and video connections, ScreenCaptureKit, hardware H.264 encode/decode, Metal presentation, input injection, display switching, basic statistics, clipboard text and reconnection backoff are connected end to end. Device profiling and the remaining product phases are still required before calling it production-ready.

## Requirements

- Xcode 26.6 or later (the project was validated with build 17F113)
- macOS 15+
- iPadOS 18+
- A development team for device signing and privacy-permission testing
- A physical Mac and iPad for end-to-end latency, hardware codec, pointer, and permission validation

No third-party runtime dependencies are used.

## Project layout

```text
nubo/
├── Apps/
│   ├── Mac/                  # NuboMac lifecycle, menu bar and permissions UI
│   └── iPad/                 # NuboiPad onboarding, discovery, session and input UI
├── Config/                   # Info.plist and entitlements per target
├── Docs/
├── Packages/NuboKit/
│   ├── Sources/
│   │   ├── NuboCore/        # models, adaptation, instrumentation, clipboard guard
│   │   ├── NuboProtocol/    # versioned messages and binary framing
│   │   ├── NuboNetworking/  # endpoint/discovery/pairing/keychain abstractions
│   │   ├── NuboVideo/       # capture/codec/rendering boundaries
│   │   ├── NuboAudio/       # audio boundaries
│   │   ├── NuboInput/       # coordinate/HID mapping and macOS event injection
│   │   └── NuboDesign/      # restrained shared visual tokens
│   └── Tests/
└── nubo.xcodeproj
```

The package modules represent real performance and ownership boundaries. Apps own presentation and lifecycle only. Mutable stream adaptation and clipboard state are actor-isolated. Capture and codec callbacks use dedicated high-priority queues and small, explicit buffers.

## Build and test

Open `nubo.xcodeproj`, select either `NuboMac` or `NuboiPad`, choose a signing team, and run.

Command-line validation without signing:

```sh
xcodebuild -project nubo.xcodeproj -scheme NuboMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project nubo.xcodeproj -scheme NuboiPad \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

cd Packages/NuboKit && swift test
```

## Architecture

### Endpoints and discovery

`ConnectionEndpoint` has independent Bonjour and manual cases. `BonjourDiscoveryService` emits an `AsyncStream` of hosts through `NWBrowser`. A manual endpoint validates an IP address or any resolvable hostname and defaults to port `49832`. Neither the session nor media pipelines know how the endpoint was discovered.

### Protocol

Protocol v1 uses a fixed 12-byte big-endian envelope:

```text
magic(4) | version(2) | channel(1) | flags(1) | payloadLength(4) | payload
```

Payloads are currently Codable JSON to make the first transport milestone inspectable and safe to evolve. The envelope allows a later binary payload codec without changing channel routing. Frames are bounded to 32 MiB and the incremental decoder handles fragmentation and coalesced reads.

Channels are explicit: session, video, audio, input, clipboard, control, statistics, and configuration.

### Transport decision

Current and intended split:

| Traffic | MVP transport | Planned transport |
|---|---|---|
| Session, input, configuration, clipboard | Dedicated encrypted TCP connection | TLS/QUIC reliable stream |
| Video | Separate encrypted TCP connection | QUIC datagrams after fragmentation/FEC evaluation |
| Audio | Not connected yet | Separate QUIC stream/datagrams after measurement |

The MVP already prevents video from blocking input by using separate connections. Media still has head-of-line blocking inside its own TCP stream, so QUIC datagrams remain a measured optimization rather than an untested claim. No WebRTC, ICE, STUN, or TURN is introduced.

### Pairing and security

LAN is treated as hostile. Initial pairing exchanges only ephemeral public material, uses P-256 ECDH and HKDF-SHA256 transcript binding, and displays the same six-digit confirmation value on both devices. After both people approve, the high-entropy peer secret is stored as a this-device-only Keychain item. Application messages use directional ChaCha20-Poly1305 keys, authenticated counters and replay rejection. Reconnection uses fresh nonces and HMAC-SHA256 mutual proof before deriving new session keys. There is no plaintext application-message fallback.

The six-digit value is only a human confirmation fingerprint; it is not used as the encryption key.

### Video and latency

The Mac capture path uses ScreenCaptureKit and native NV12 output, which VideoToolbox can consume without a BGRA conversion. Capture queue depth is 3, audio is a separate output, and the initial frame interval is configurable up to 60 FPS. H.264 encoding:

- requires hardware acceleration;
- enables real-time mode;
- disables frame reordering/B-frames;
- sets expected FPS, average bitrate, and keyframe interval;
- rebuilds only when dimensions change; bitrate/FPS update in place.

`LatestFrameMailbox` is a single-slot handoff to the Metal renderer: a new frame replaces an unrendered old frame. SwiftUI never owns the per-frame image pipeline.

Target latency instrumentation points are capture, encode, network, decode, render, and input return. `NuboLog` provides bounded OSLog categories and `NuboSignpost` provides Instruments intervals without production print spam.

### Adaptive streaming

The controller consumes RTT, jitter, packet loss, throughput, FPS, dropped frames, and stage latency. It uses consecutive-sample thresholds and a cooldown to prevent oscillation. Degradation order is bitrate, resolution, then FPS; recovery is deliberately slower and reverses that order.

## Permissions

NuboMac checks Screen Recording using `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` and Accessibility using `AXIsProcessTrustedWithOptions`. Essential missing permissions keep Finish disabled. Local Network has no direct request API on macOS; publishing the Bonjour listener triggers the system decision.

After onboarding the main window closes. `LSUIElement` keeps Nubo out of the Dock and `MenuBarExtra` remains available. Start at Login uses `SMAppService.mainApp`, not a legacy login-item helper.

NuboiPad declares `_nubo._tcp` in `NSBonjourServices` and provides the local-network usage description.

## Known iPadOS limitations

- UIKit reports physical-keyboard presses through the active responder chain and provides USB HID usage codes, which Nubo captures in its dedicated `UIView` input surface.
- iPadOS always gets the first opportunity to handle key commands. `wantsPriorityOverSystemBehavior` can prioritize an app command over text input/focus, but it does not grant global keyboard interception.
- System-reserved shortcuts can remain unavailable. In particular, Nubo cannot promise to forward combinations consumed by iPadOS, such as app switching and system search (`Command-Tab`, `Command-Space`) or system/global Globe-key shortcuts. The exact set can vary by OS release and user keyboard settings.
- Copy/paste commands may be routed to responder actions by UIKit. Nubo provides an explicit clipboard-send toolbar action; deeper `UIKeyCommand` integration remains necessary for seamless shortcut behavior.
- An iPad app cannot continue a low-latency interactive remote-desktop session indefinitely in the background. Nubo pauses capture/decoding and reconnects on foreground instead of abusing background modes.

Apple references: [physical keyboard events](https://developer.apple.com/documentation/uikit/handling-key-presses-made-on-a-physical-keyboard), [UIKeyCommand](https://developer.apple.com/documentation/uikit/uikeycommand), and [wantsPriorityOverSystemBehavior](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior).

## Tests

The initial suite covers:

- protocol round trips, fragmented reads, coalesced reads, and invalid framing;
- coordinate conversion including Retina scale and negative display origins;
- bitrate-first adaptation and gradual recovery;
- manual/Tailscale-style endpoint validation;
- two-party pairing secret/code agreement;
- clipboard echo prevention.

ScreenCaptureKit and VideoToolbox are deliberately not mocked as if CI could validate hardware or privacy behavior. Their configuration is isolated behind interfaces for device integration tests.

## Roadmap

- [x] Phase 1 — project, two application targets, internal modules, build and unit tests
- [x] Phase 2 — authenticated encrypted transport, secure listener, pairing approval UI, reconnection backoff
- [x] Phase 3 — ScreenCaptureKit → iPad Metal baseline path
- [x] Phase 4 — binary H.264 transport and hardware decode; physical-device 60 FPS validation pending
- [x] Phase 5 — baseline mouse/trackpad/keyboard delivery; reserved shortcuts documented
- [ ] Phase 6 — gesture arbitration, drag, Pencil refinement
- [x] Phase 7 — basic live FPS/bitrate/RTT and bitrate adaptation; capture resizing refinement pending
- [ ] Phase 8 — AAC audio path and A/V clock handling
- [x] Phase 9 — bidirectional text clipboard with explicit iPad send action
- [x] Phase 10 — display enumeration/switching; All Displays evaluation pending
- [x] Phase 11 — host permissions/listener/menu integration
- [ ] Phase 12 — device-tested UI polish, Stage Manager and Split View
- [ ] Phase 13 — Instruments profiles, energy, CPU/GPU/memory/network optimization

Each phase must leave both app schemes building, run the package tests, and update this status rather than accumulating known failures.
