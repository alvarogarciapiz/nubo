# Device test checklist

The simulator validates UI and protocol logic, but ScreenCaptureKit permissions, hardware H.264, Magic Keyboard input and real latency require physical devices.

## First connection

1. Run `NuboMac` on macOS 15 or newer.
2. Allow Screen Recording and Accessibility. macOS may require restarting Nubo after Screen Recording approval.
3. Continue through Local Network and finish onboarding. Confirm Nubo remains only in the menu bar.
4. Run `NuboiPad` on an iPadOS 18 or newer device on the same Wi-Fi.
5. Complete onboarding and select the advertised Mac.
6. Type the Mac’s six-digit code on the iPad and approve the named iPad on the Mac.
7. Confirm that the Mac desktop appears.

## Interaction

- Move one finger to test relative cursor motion. Use the Magic Keyboard trackpad to test precise aspect-fit alignment with the streamed Mac cursor.
- Test tap/click, double-click, two-finger tap/right-click, and two-axis scroll.
- Test letters, arrows, Return, Tab, Escape, Delete and non-reserved modifier combinations on a physical keyboard.
- Copy text on iPad, return to Nubo, choose More → Send Clipboard, then paste on Mac.
- Copy text on Mac and verify the iPad pasteboard receives it.
- Use Display in the toolbar to switch monitors.
- Enable Show Connection Stats and inspect FPS, received bitrate and RTT.

## Recovery

- Disable Wi-Fi briefly and verify `Reconnecting…` plus bounded exponential retries. After retries are exhausted, verify that `Try Again` starts a fresh attempt.
- Background and foreground NuboiPad; resources should close and the authenticated session should reconnect.
- Restart the local network while the home screen is visible and verify Bonjour discovery resumes without relaunching Nubo.
- Sleep and wake the Mac. Full sleep/wake republishing is still a hardening item.

## Known product-candidate gaps

- Audio transport is not connected.
- Touch drag, centered pinch zoom and basic Pencil pointing are implemented; hardware validation and zoom panning remain pending.
- Video uses its own encrypted TCP connection, not QUIC datagrams. It cannot block input, but packet loss can temporarily stall video.
- Adaptive bitrate, capture resolution and FPS updates are active; their thresholds still need device and Wi-Fi profiling.
- A physical-device pass is required to validate color, rotation, thermal behavior and measured 60 FPS.
- System-reserved iPadOS shortcuts cannot be intercepted reliably.

See [the interaction upgrade checklist](INTERACTION-VALIDATION.md) for protocol-v4 pairing, Retina quality, gestures, shortcuts and visual checks.
