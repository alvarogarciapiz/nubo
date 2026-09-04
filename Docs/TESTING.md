# Device test checklist

The simulator validates UI and protocol logic, but ScreenCaptureKit permissions, hardware H.264, Magic Keyboard input and real latency require physical devices.

## First connection

1. Run `NuboMac` on macOS 15 or newer.
2. Allow Screen Recording and Accessibility. macOS may require restarting Nubo after Screen Recording approval.
3. Continue through Local Network and finish onboarding. Confirm Nubo remains only in the menu bar.
4. Run `NuboiPad` on an iPadOS 18 or newer device on the same Wi-Fi.
5. Complete onboarding and select the advertised Mac.
6. Verify the same six-digit code on both devices, then approve both prompts.
7. Confirm that the Mac desktop appears.

## Interaction

- Move one finger or the Magic Keyboard trackpad and verify relative cursor motion.
- Test tap/click, double-click, two-finger tap/right-click, and two-axis scroll.
- Test letters, arrows, Return, Tab, Escape, Delete and non-reserved modifier combinations on a physical keyboard.
- Copy text on iPad, return to Nubo, tap the clipboard icon, then paste on Mac.
- Copy text on Mac and verify the iPad pasteboard receives it.
- Use Display in the toolbar to switch monitors.
- Enable Show Connection Stats and inspect FPS, received bitrate and RTT.

## Recovery

- Disable Wi-Fi briefly and verify `Reconnecting…` plus bounded exponential retries.
- Background and foreground NuboiPad; resources should close and the authenticated session should reconnect.
- Sleep and wake the Mac. Full sleep/wake republishing is still a hardening item.

## Known MVP gaps

- Audio transport is not connected.
- Touch drag arbitration, pinch-to-zoom and Apple Pencil refinement are incomplete.
- Video uses its own encrypted TCP connection, not QUIC datagrams. It cannot block input, but packet loss can temporarily stall video.
- Adaptive bitrate updates are active; dynamic capture-resolution and FPS changes need device profiling.
- A physical-device pass is required to validate color, rotation, thermal behavior and measured 60 FPS.
- System-reserved iPadOS shortcuts cannot be intercepted reliably.
