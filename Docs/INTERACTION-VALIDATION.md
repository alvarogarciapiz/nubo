# Interaction upgrade — September 2026

Install both protocol-v4 builds. Existing Keychain pairings are retained; first-time typed pairing needs a previously unpaired device (or deliberate credential removal outside this checklist).

## Physical-device checks

1. Enable connection statistics. Compare Automatic and Maximum Detail with small black and colored text. Record the displayed encoded dimensions, FPS and bitrate. Rotate the iPad and resize its window; allow a second for the request to settle. Maximum Detail requests a 3840-pixel long edge, not lossless encoding.
2. Hover and click near all four desktop corners, the center, and beside letterbox bars. The native iPad cursor should respond immediately; the embedded Mac cursor should disappear after switching to mouse input. Touch motion restores the embedded cursor. Switch to a display arranged left/above the main display and repeat. Mac cursor shapes (I-beam, resize) are not yet synchronized.
3. With a mouse or Magic Keyboard trackpad, press and hold while dragging a window or selecting text. Test secondary click, continuous two-finger scrolling and a physical scroll wheel.
4. With touch, test immediate tap, double tap, one-finger motion, stationary hold followed by drag, two-finger right-click and two-finger scroll. Ordinary motion must not start a drag after the long-press delay. Pinch to zoom and check that mouse clicks still target the corresponding desktop point. Reset Zoom is in More.
5. Test physical Command-W/Q/C/V and plain typing without doubled characters. Test More → Spotlight / Switch App / Close Window / Quit App; these actions send directly to the Mac. Record which physical shortcuts iPadOS consumes. No global shortcut interception is claimed.
6. Open Settings or pairing while a physical keyboard is attached. Typing must target the presented UI, not the remote desktop. Test cancel/disconnect while dragging; no button or modifier should remain held on the Mac.
7. On a fresh pairing, enter a wrong code, then the correct code, and approve the named iPad on the Mac. Test denial and the two-minute expiry separately. Reconnect through Bonjour and through the same manual endpoint: neither should ask again after it has stored that endpoint's authenticated identity.
8. Check onboarding with no permissions, partial permissions and all permissions. Instructions should remain scrollable, the primary action visible, and completion explicit. Check the menu bar in light/dark appearance: a cloud silhouette only.

## Automated coverage

Additional regression checks: deny Screen Recording and verify a visible host error rather than a silently empty display menu. Restore permission and retry. Pair a fresh device by scanning the QR, then quit/relaunch both apps and confirm no code or camera is requested. Deny camera access and verify manual pairing remains usable. Customize a home tile, relaunch, and verify its local name/icon persist. The Mac product is now Nubo.app (bundle identity unchanged); quit the previous copy before launching the new one.

Tests cover aspect-fit/letterbox/zoom coordinate mapping; Retina pixel budgets; even dimensions and 30 FPS limits; recovery of the requested resolution; exact typed code matching; commitment/identity binding; denied pairing without persisted credentials; and encrypted pairing/resume/input round trips. These do not certify hardware FPS, gesture delivery by an actual Magic Keyboard, or Mac privacy permissions.

HardwareEncoderTests now encodes a synthetic 2732×2048 NV12 frame through the real H.264 hardware encoder and requires an initial keyframe with parameter sets. It passed on the local Mac; only unavailable-hardware errors skip on CI. This tests encoder startup, not ScreenCaptureKit permissions, sustained 60 FPS, or end-to-end LAN latency. The QR parser is also tested against malformed payloads, unsupported versions and unrelated URLs.

## Design references

- [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials): glass belongs to navigation and transient controls.
- [Apple: Handle trackpad and mouse input](https://developer.apple.com/videos/play/wwdc2020/10094/): indirect-pointer events and scroll masks.
- [Apple: Key command priority](https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior): priority over text input/focus, not global interception.
- [ChatGPT release notes, August 2026](https://help.openai.com/en/articles/6825453-chatgpt-release-notes): clearer connection states and progressive access to actions. The notes do not specify a full visual design system; Nubo uses its own layout and native Apple controls.
