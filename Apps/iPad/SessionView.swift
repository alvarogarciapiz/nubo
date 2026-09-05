import NuboCore
import NuboDesign
import NuboProtocol
import NuboVideo
import SwiftUI

struct SessionView: View {
    @Bindable var model: iPadAppModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var keyboardRequest = 0
    @State private var zoom: CGFloat = 1
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage("showConnectionStats") private var showConnectionStats = false
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.0
    @AppStorage("trackpadGestures") private var trackpadGestures = true
    @AppStorage("streamingQuality") private var streamingQuality = "automatic"
    @AppStorage("frameRate") private var frameRate = "automatic"
    @AppStorage("matchDesktopViewport") private var matchDesktopViewport = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                ZStack {
                    RemoteVideoSurface(mailbox: model.frameMailbox, zoom: zoom)
                    RemoteInputSurface(
                        pointerSpeed: pointerSpeed,
                        trackpadGesturesEnabled: trackpadGestures,
                        keyboardRequest: keyboardRequest,
                        isActive: model.connectionState == .connected && !model.showPairingConfirmation && !model.showSettings,
                        display: model.selectedDisplay,
                        zoom: zoom,
                        onZoom: { zoom = $0 },
                        onRevealControls: revealControls,
                        onEvent: model.send
                    )
                    .allowsHitTesting(model.connectionState == .connected && !model.showPairingConfirmation && !model.showSettings)
                }
                .onAppear { model.updateViewport(geometry.size, scale: displayScale) }
                .onChange(of: geometry.size) { _, size in model.updateViewport(size, scale: displayScale) }
            }
            .ignoresSafeArea()

            connectionOverlay

            if controlsVisible {
                VStack {
                    sessionToolbar
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .transition(.opacity)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        toolbarButton("Show Session Controls", systemImage: "ellipsis", action: revealControls)
                            .foregroundStyle(.white)
                            .nuboControlSurface(cornerRadius: 10)
                            .environment(\.colorScheme, .dark)
                    }
                    Spacer()
                }
                .padding(16)
            }

            if showConnectionStats {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Text("\(Int(model.metrics.framesPerSecond)) FPS")
                        Text(String(format: "%.1f Mbps", Double(model.metrics.bitrate) / 1_000_000))
                        Text(String(format: "RTT %.1f ms", model.metrics.rttMilliseconds))
                        Text("\(model.videoWidth)×\(model.videoHeight)")
                        Text(model.videoCodec == .hevc ? "HEVC" : "H.264")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        .black.opacity(0.78),
                        in: RoundedRectangle(cornerRadius: NuboDesign.smallRadius, style: .continuous)
                    )
                    .padding(.bottom, 18)
                }
            }
        }
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.applyStreamingPreferences(quality: streamingQuality, frameRate: frameRate)
            if model.connectionState == .connected { scheduleHide() }
        }
        .onChange(of: streamingQuality) { _, value in
            model.applyStreamingPreferences(quality: value, frameRate: frameRate)
        }
        .onChange(of: frameRate) { _, value in
            model.applyStreamingPreferences(quality: streamingQuality, frameRate: value)
        }
        .onChange(of: matchDesktopViewport) { _, _ in model.applyDesktopViewport() }
        .onChange(of: model.connectionState) { _, state in
            if state == .connected {
                scheduleHide()
            } else {
                hideTask?.cancel()
                withAnimation(NuboDesign.quietAnimation) { controlsVisible = true }
            }
        }
        .onDisappear {
            hideTask?.cancel()
            if model.connectionState != .idle { model.disconnect() }
        }
        .sheet(isPresented: $model.showSettings) { iPadSettingsView() }
    }

    private var sessionToolbar: some View {
        HStack(spacing: 2) {
            toolbarButton("Close Session", systemImage: "xmark") {
                model.disconnect()
            }

            Divider()
                .frame(height: 22)
                .overlay(.white.opacity(0.16))
                .padding(.horizontal, 3)

            Menu {
                if model.displays.isEmpty {
                    Text("Waiting for Mac displays…")
                } else {
                    ForEach(model.displays) { display in
                        Button(display.name) { model.send(.selectDisplay(display.id)) }
                    }
                }
                Divider()
                Toggle("Match Desktop to iPad", isOn: $matchDesktopViewport)
                if !model.desktopViewportStatus.isEmpty { Text(model.desktopViewportStatus) }
            } label: {
                Group {
                    if horizontalSizeClass == .compact {
                        Image(systemName: "display")
                            .frame(width: NuboDesign.minimumHitTarget)
                    } else {
                        Label("Display", systemImage: "display")
                            .padding(.horizontal, 10)
                    }
                }
                .font(.callout.weight(.medium))
                .frame(minHeight: NuboDesign.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Choose Display")
            .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })

            Divider()
                .frame(height: 22)
                .overlay(.white.opacity(0.16))
                .padding(.horizontal, 3)

            toolbarButton("Show Keyboard", systemImage: "keyboard") {
                keyboardRequest &+= 1
            }
            Menu {
                Section("Send to Mac") {
                    Button("Spotlight  ⌘Space") { model.sendShortcut(hidUsage: 0x2C) }
                    Button("Switch App  ⌘Tab") { model.sendShortcut(hidUsage: 0x2B) }
                    Button("Close Window  ⌘W") { model.sendShortcut(hidUsage: 0x1A) }
                    Button("Quit App  ⌘Q") { model.sendShortcut(hidUsage: 0x14) }
                    Button("Escape") { model.sendShortcut(hidUsage: 0x29, modifiers: []) }
                }
                Button("Send Clipboard", systemImage: "doc.on.clipboard") { model.sendClipboard() }
                Button("Reset Zoom", systemImage: "arrow.up.left.and.arrow.down.right") { zoom = 1 }
                Button("Settings…", systemImage: "gearshape") { model.showSettings = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Mac Shortcuts and Settings")
            .simultaneousGesture(TapGesture().onEnded { hideTask?.cancel() })
        }
        .foregroundStyle(.white)
        .padding(6)
        .nuboControlSurface()
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func toolbarButton(
        _ accessibilityLabel: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: NuboDesign.minimumHitTarget, height: NuboDesign.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var connectionOverlay: some View {
        switch model.connectionState {
        case .connected:
            if !model.hasReceivedVideo {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Starting Mac display…").foregroundStyle(.white.opacity(0.72))
                }
            }
        case let .unavailable(reason):
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 28, weight: .medium))
                Text("Mac unavailable")
                    .font(.headline)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 10) {
                    Button("Disconnect") { model.disconnect() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 9))
                    Button("Try Again") { model.retryConnection() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 9))
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(28)
            .nuboControlSurface(cornerRadius: 16)
            .environment(\.colorScheme, .dark)
        default:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var statusText: String {
        switch model.connectionState {
        case .connecting: "Connecting to \(model.selectedHostName)…"
        case .pairing: model.showPairingConfirmation ? "Enter the code from your Mac" : "Waiting for approval on your Mac…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case let .unavailable(reason): reason
        case .idle: "Disconnected"
        }
    }

    private func revealControls() {
        withAnimation(reduceMotion ? nil : NuboDesign.quietAnimation) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.connectionState == .connected, !voiceOver else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : NuboDesign.quietAnimation) { controlsVisible = false }
        }
    }
}

private struct RemoteVideoSurface: UIViewRepresentable {
    let mailbox: LatestFrameMailbox
    let zoom: CGFloat

    func makeUIView(context: Context) -> MetalVideoView {
        MetalVideoView(mailbox: mailbox)
    }

    func updateUIView(_ uiView: MetalVideoView, context: Context) { uiView.setZoom(zoom) }
}
