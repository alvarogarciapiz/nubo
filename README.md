# Nubo

Nubo is an open-source, native macOS and iPadOS remote desktop app focused on low latency, precise input, and local-first privacy. `NuboMac` runs as the host on your Mac and `NuboiPad` runs as the client on your iPad.

No cloud relays, no accounts, and zero third-party dependencies.

## Requirements

- **Mac**: macOS 15+
- **iPad**: iPadOS 18+
- **Xcode**: Xcode 26.6+ (to build and deploy to your devices)
- An Apple ID in Xcode for local device signing (a free personal Apple ID works)

## Installation

You do not need an App Store distribution account. You can build and deploy both apps directly to your own Mac and iPad from Xcode:

1. **Clone the repository**
   ```sh
   git clone https://github.com/alvarogarciapiz/nubo.git
   cd nubo
   ```

2. **Configure signing in Xcode**
   - Open `nubo.xcodeproj`.
   - Select the `NuboMac` target → **Signing & Capabilities** → choose your **Team** (your Apple ID).
   - Select the `NuboiPad` target → **Signing & Capabilities** → choose your **Team** (and change the **Bundle Identifier** if Xcode reports it is already registered, e.g. `com.yourname.Nubo`).

3. **Build and run**
   - Select the `NuboMac` scheme, choose **My Mac**, and press **Run** (`⌘R`).
   - Connect your iPad (via USB-C or Wi-Fi), select the `NuboiPad` scheme, choose your iPad, and press **Run** (`⌘R`).

4. **Grant permissions & pair**
   - On your Mac, grant **Screen Recording** and **Accessibility** permissions when prompted by `NuboMac`.
   - Open `NuboiPad` on your iPad. Your Mac will appear automatically via Bonjour (or enter your Mac's local IP / Tailscale hostname manually on port `49832`).
   - Confirm the 6-digit pairing code (or scan the QR code) shown on your Mac.

### Command-line build & tests

You can also validate builds without signing and run the `NuboKit` test suite:

```sh
xcodebuild -project nubo.xcodeproj -scheme NuboMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project nubo.xcodeproj -scheme NuboiPad \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

cd Packages/NuboKit && swift test
```

## Project Layout

```text
nubo/
├── Apps/
│   ├── Mac/                  # NuboMac host app (menu bar, permissions, lifecycle)
│   └── iPad/                 # NuboiPad client app (discovery, session, input UI)
├── Config/                   # Info.plist and entitlements per target
├── Docs/                     # Architecture, testing, and interaction docs
├── Packages/NuboKit/
│   ├── Sources/
│   │   ├── NuboCore/         # Models, adaptive quality, instrumentation, clipboard
│   │   ├── NuboProtocol/     # Versioned v4 binary framing and messages
│   │   ├── NuboNetworking/   # Bonjour, manual endpoints, pairing, Keychain
│   │   ├── NuboVideo/        # ScreenCaptureKit, VideoToolbox H.264, Metal
│   │   ├── NuboAudio/        # Audio boundaries
│   │   ├── NuboInput/        # Coordinate mapping and Quartz event injection
│   │   └── NuboDesign/       # Shared SwiftUI visual tokens
│   └── Tests/                # Unit and loopback integration tests
└── nubo.xcodeproj
```

## How It Works

- **Video pipeline**: Captures the Mac display with `ScreenCaptureKit` (native NV12), encodes in hardware via `VideoToolbox` (H.264, real-time, no B-frames), and renders directly with `Metal` on iPadOS. Adapts bitrate, resolution, and FPS dynamically based on RTT, jitter, and packet loss.
- **Pairing & encryption**: Treats the LAN as untrusted. Initial pairing uses P-256 ECDH with HKDF-SHA256 and a 6-digit out-of-band confirmation code. Paired credentials are stored in the local Keychain, and control, input, and video streams run over separate `ChaCha20-Poly1305` encrypted TCP connections.
- **LAN & Tailscale**: Bonjour (`_nubo._tcp`) handles automatic local discovery, while manual IP/hostname endpoints (default port `49832`) let you connect over Tailscale or WireGuard without changing the session pipeline.

## Known iPadOS Limitations

- iPadOS intercepts system-reserved shortcuts like `Command-Tab` and `Command-Space` before apps can receive them. The in-session **More** menu provides explicit actions to send `Command-Space`, `Command-Tab`, `Command-W`, `Command-Q`, and `Escape` to the Mac.
- iPadOS suspends backgrounded apps, so `NuboiPad` pauses streaming when backgrounded and reconnects when brought back to the foreground.

## License

MIT License — see [LICENSE](LICENSE) for details.
