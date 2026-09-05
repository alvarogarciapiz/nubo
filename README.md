# Nubo

Nubo is a native macOS/iPadOS remote-desktop system focused on low latency, precise input, and predictable behavior on a local network. `NuboMac` is the host and `NuboiPad` is the client. Bonjour is only a discovery mechanism: manual IP and hostname endpoints use the same session architecture, so a future Tailscale hostname does not require changes to video, audio, input, pairing, or session logic.

> Current milestone: hardened LAN product candidate. Discovery/manual connection, mutually confirmed pairing, independently encrypted control/input/video connections, ScreenCaptureKit, hardware H.264 encode/decode, Metal presentation, input injection, display switching, statistics, adaptive capture, clipboard text and generation-safe reconnection are connected end to end. A physical-device qualification pass and the remaining features listed below are still required before a public production release.

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

### Interface

The UI is native SwiftUI. Navigation stacks, lists, forms, menus, alerts, settings and semantic system text styles provide platform behavior, Dynamic Type and accessibility without reproducing system controls. Content hierarchy comes from spacing, typography and separators rather than decorative cards, colored icon containers or nested surfaces.

On iPadOS 26 and macOS 26, the shared design layer applies `glassEffect` only to the transient remote-session control surface. Earlier supported systems fall back to a native material with the same layout. Liquid Glass is deliberately absent from content rows and onboarding content, keeping it as a functional layer instead of decoration. Transitions respect Reduce Motion.

### Endpoints and discovery

`ConnectionEndpoint` has independent Bonjour and manual cases. `BonjourDiscoveryService` emits an `AsyncStream` of hosts through `NWBrowser`. A manual endpoint validates an IP address or any resolvable hostname and defaults to port `49832`. Neither the session nor media pipelines know how the endpoint was discovered.

### Protocol

Protocol v4 uses a fixed 12-byte big-endian envelope. Update both apps together; older builds cannot connect:

```text
magic(4) | version(2) | channel(1) | flags(1) | payloadLength(4) | payload
```

Control/configuration payloads use Codable JSON so they remain inspectable and easy to evolve. Video, audio and high-frequency pointer/keyboard events use compact binary payloads to avoid JSON allocation and parsing on the latency-sensitive path. Frames are bounded to 32 MiB and the incremental decoder handles fragmentation and coalesced reads; unauthenticated bootstrap frames are separately capped at 64 KiB.

Channels are explicit: session, video, audio, input, clipboard, control, statistics, and configuration.

### Transport decision

Current and intended split:

| Traffic | MVP transport | Planned transport |
|---|---|---|
| Session, configuration, clipboard | Encrypted low-latency TCP control connection | QUIC reliable stream if measurements justify it |
| Pointer and keyboard input | Dedicated encrypted low-latency TCP connection | Keep reliable and isolated |
| Video | Separate encrypted TCP connection | QUIC datagrams after fragmentation/FEC evaluation |
| Audio | Not connected yet | Separate QUIC stream/datagrams after measurement |

Video, input and control have separate authenticated connections, with TCP no-delay, interactive service classes, five-second connection timeout and keepalive failure detection. Media still has head-of-line blocking inside its own TCP stream, so QUIC datagrams remain a measured optimization rather than an untested claim. No WebRTC, ICE, STUN, or TURN is introduced.

When the latest-frame policy drops an encoded inter-frame under backpressure, the iPad detects the sequence gap and requests an immediate H.264 keyframe. This restores a clean decoder reference chain without accumulating stale video.

### Pairing and security

LAN is treated as hostile. Bootstrap messages validate protocol compatibility and exchange public handshake material. Pairing uses P-256 ECDH and HKDF-SHA256 transcript binding. Both devices compute a six-digit confirmation value, displayed only on the Mac and entered manually on the iPad. After approval and encrypted key confirmation, the high-entropy peer secret is stored as a this-device-only Keychain item. Application messages use directional ChaCha20-Poly1305 keys, authenticated counters and replay rejection. Reconnection uses fresh nonces and HMAC-SHA256 mutual proof before deriving new session keys. There is no plaintext application-message fallback.

The six-digit value is only a human confirmation fingerprint; it is not used as the encryption key.

First pairing requires typing the Mac's six-digit code or scanning its QR inside Nubo, and approving the named iPad on the Mac. The QR contains only the confirmation value for the current ephemeral handshake: it is not an address or a persistent credential. Three incorrect entries reject that attempt; approval expires after two minutes. Both peers commit to their handshake before revealing their ephemeral keys, and these commitments bind device IDs, names and protocol version into the key agreement. An encrypted key-confirmation exchange must succeed before trust is saved. Future connections reuse Keychain credentials without showing either code or QR. Pending handshakes are bounded and have deadlines. The host also spaces new pairing attempts by five seconds. This is a custom protocol built from CryptoKit primitives; it still needs an independent security review before a public release. Camera denial or unsupported scanning leaves manual entry available.

Existing paired identities remain in Keychain. Manual endpoints remember the authenticated peer ID and resume using its stored credential; a failed identity check never silently falls back to pairing a different Mac.

### Video and latency

Automatic quality uses the current iPad view's physical pixels instead of a fixed 1920×1200 profile. The client requests up to a 3200-pixel long edge in Automatic/High, or 3840 in Maximum Detail, with a bitrate budget up to 45 Mbps. The host fits this request to the display's aspect ratio and available backing pixels. This preserves Retina detail and adapts to rotation and window resizing. The quality controller remembers the requested resolution and FPS ceiling, including an explicit 30 FPS choice. H.264 remains lossy 4:2:0, so small colored text cannot be promised to match a local display pixel for pixel.

Mouse/trackpad hover maps into the exact aspect-fit video rectangle, including zoom, Retina scale and negative display origins. The native iPad pointer responds locally; the host stops embedding its cursor when it receives absolute pointer input. Direct touch remains relative and restores the embedded cursor when moving. This avoids waiting for video round-trip to see mouse motion, but does not yet transmit the Mac's changing cursor shape. Mouse button-down/up is delivered independently from touch tap recognizers; continuous trackpad and wheel scrolling is explicitly enabled. Pinch zoom is local (1–3×), centered on the view, and does not change the Mac's resolution. Three-finger tap or the visible More affordance reveals session controls. Arbitrary zoom panning and pointer-lock/raw-relative mouse mode remain future refinements.

The Mac capture path uses ScreenCaptureKit and native NV12 output, which VideoToolbox can consume without a BGRA conversion. Capture queue depth is 2, audio is a separate output, and the frame interval is configurable up to 60 FPS. H.264 encoding:

- requires hardware acceleration;
- enables real-time mode;
- disables frame reordering/B-frames;
- sets expected FPS, average bitrate, and keyframe interval;
- rebuilds only when dimensions change; bitrate/FPS update in place.

The encoded network sender and decoded renderer both use single-slot latest-frame handoffs: superseded frames are discarded rather than accumulated as latency, while a pending keyframe is preserved. Metal presents through an explicit command buffer with at most two drawables. SwiftUI never owns the per-frame image pipeline.

Target latency instrumentation points are capture, encode, network, decode, render, and input return. `NuboLog` provides bounded OSLog categories and `NuboSignpost` provides Instruments intervals without production print spam.

### Adaptive streaming

The controller consumes RTT, jitter, packet loss, throughput, FPS, dropped frames, and stage latency. It uses consecutive-sample thresholds and a cooldown to prevent oscillation. Degradation order is bitrate, resolution, then FPS; recovery is deliberately slower and reverses that order. Resolution and FPS changes now update ScreenCaptureKit as well as VideoToolbox, so adaptation changes actual capture cost and network load.

## Permissions

NuboMac checks Screen Recording using `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` and Accessibility using `AXIsProcessTrustedWithOptions`. Essential missing permissions keep Finish disabled. Local Network has no direct request API on macOS; publishing the Bonjour listener triggers the system decision.

After onboarding the main window closes. `LSUIElement` keeps Nubo out of the Dock and `MenuBarExtra` remains available. Start at Login uses `SMAppService.mainApp`, not a legacy login-item helper.

NuboiPad declares `_nubo._tcp` in `NSBonjourServices` and provides the local-network usage description.

## Known iPadOS limitations

- UIKit reports physical-keyboard presses through the active responder chain and provides USB HID usage codes, which Nubo captures in its dedicated `UIView` input surface.
- iPadOS always gets the first opportunity to handle key commands. `wantsPriorityOverSystemBehavior` can prioritize an app command over text input/focus, but it does not grant global keyboard interception.
- System-reserved shortcuts can remain unavailable. In particular, Nubo cannot promise to forward combinations consumed by iPadOS, such as app switching and system search (`Command-Tab`, `Command-Space`) or system/global Globe-key shortcuts. The exact set can vary by OS release and user keyboard settings.
- Nubo registers priority `UIKeyCommand` actions for common Mac shortcuts and consumes handled hardware presses to avoid duplicate text delivery. This does not override OS-reserved global shortcuts. The session More menu explicitly sends Command-Space, Command-Tab, Command-W, Command-Q and Escape to the Mac even when the corresponding physical shortcut is consumed by iPadOS.
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
- full loopback pairing, encrypted reconnection, isolated input transport, RTT sampling and encrypted payload throughput.

The loopback performance test is a regression guard for protocol/framing overhead, not a substitute for Wi-Fi measurement. Its observed values are printed by the test run so changes can be compared over time.

## Distribution status

The shared `nubo.icon` Icon Composer asset is compiled for both targets; Xcode generates the macOS `.icns` and iPad icon renditions. Both platform targets use the same bundle identifier, `com.lvrpiz.Nubo`, but they necessarily produce separate native `.app` bundles for different operating systems.

Apple supports one universal-purchase App Store Connect record for native iPadOS and macOS targets with the same bundle ID. NuboMac, however, must synthesize keyboard and pointer events to control arbitrary apps. Apple documents accessibility/event-simulation functionality as restricted by App Sandbox, while the Mac App Store requires App Sandbox. Shipping a sandboxed host would therefore risk passing compilation while losing Nubo's core input behavior.

The production-safe distribution plan is currently:

- NuboiPad through one iPadOS App Store Connect record;
- NuboMac signed with Developer ID, hardened, notarized and distributed directly;
- one repository, shared protocol/modules and the same bundle identifier on both platforms.

Do not add the macOS platform to the App Store record until a signed sandbox build has passed end-to-end `CGEvent` validation and Apple has confirmed the review path. If Apple grants a suitable entitlement or policy path later, the existing same identifier allows the macOS platform to be added without restructuring the codebase.

ScreenCaptureKit and VideoToolbox are deliberately not mocked as if CI could validate hardware or privacy behavior. Their configuration is isolated behind interfaces for device integration tests.

## Roadmap

- [x] Phase 1 — project, two application targets, internal modules, build and unit tests
- [x] Phase 2 — authenticated encrypted transport, secure listener, pairing approval UI, reconnection backoff
- [x] Phase 3 — ScreenCaptureKit → iPad Metal baseline path
- [x] Phase 4 — binary H.264 transport and hardware decode; physical-device 60 FPS validation pending
- [x] Phase 5 — baseline mouse/trackpad/keyboard delivery; reserved shortcuts documented
- [ ] Phase 6 — gesture arbitration, drag, Pencil refinement
- [x] Phase 7 — live FPS/bitrate/RTT plus bitrate, capture-resolution and FPS adaptation
- [ ] Phase 8 — AAC audio path and A/V clock handling
- [x] Phase 9 — bidirectional text clipboard with explicit iPad send action
- [x] Phase 10 — display enumeration/switching; All Displays evaluation pending
- [x] Phase 11 — host permissions/listener/menu integration
- [ ] Phase 12 — device-tested UI polish, Stage Manager and Split View
- [ ] Phase 13 — Instruments profiles, energy, CPU/GPU/memory/network optimization

Each phase must leave both app schemes building, run the package tests, and update this status rather than accumulating known failures.
