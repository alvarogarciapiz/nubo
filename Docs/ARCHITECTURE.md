# Architecture notes

## Dependency direction

```text
Apps ────────────────┐
  │                  │
  ├─ NuboNetworking ─┼─ NuboProtocol ─ NuboCore
  ├─ NuboVideo ──────┤
  ├─ NuboAudio ──────┤
  ├─ NuboInput ──────┤
  └─ NuboDesign ─────┘
```

No package imports either application. Core and protocol models are UI-free. Platform APIs are guarded at the file boundary rather than scattered through shared logic.

## Concurrency ownership

- Session and transport state will be actor-owned.
- Network.framework callbacks enter a private queue and bridge to `AsyncStream`.
- ScreenCaptureKit produces frames on a `.userInteractive` serial queue.
- VideoToolbox owns codec sessions behind a lock because its callback is C-based.
- Rendering consumes a one-frame mailbox on its own display cadence.
- UI state remains `@MainActor` and receives low-frequency state/metrics updates only.

## Latency budget

Initial targets for an excellent LAN are engineering budgets, not claims:

| Stage | Target |
|---|---:|
| Capture handoff | 2–5 ms |
| Hardware encode | 3–8 ms |
| LAN transport | 1–8 ms |
| Hardware decode | 2–6 ms |
| Metal render/present | 2–8 ms |
| Total glass-to-glass | under 40 ms where hardware/network permit |

Signposts will measure the actual values. Adaptation reacts to sustained degradation, not a single noisy sample.

## Transport invariants

1. No application data is accepted before peer authentication.
2. Input and control cannot queue behind a video frame.
3. Pointer motion and video may be dropped when superseded.
4. Keyboard/button releases and configuration changes must be reliable.
5. Reconnection creates a new transport generation; late packets from an old generation are ignored.
6. Bonjour metadata is untrusted and never authorizes a peer.
