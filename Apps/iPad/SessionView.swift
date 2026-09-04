import NuboCore
import NuboDesign
import NuboProtocol
import NuboVideo
import SwiftUI

struct SessionView: View {
    @Bindable var model: iPadAppModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @AppStorage("showConnectionStats") private var showConnectionStats = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteVideoSurface(mailbox: model.frameMailbox)
                .ignoresSafeArea()

            if model.connectionState != .connected {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            RemoteInputSurface { message in
                Task { @MainActor in model.send(message) }
            }
            .contentShape(Rectangle())
            .onTapGesture { revealControls() }

            if controlsVisible {
                VStack {
                    HStack(spacing: 22) {
                        Button { model.disconnect() } label: { Image(systemName: "xmark") }
                        Spacer()
                        Menu {
                            ForEach(model.displays) { display in
                                Button(display.name) { model.send(.selectDisplay(display.id)) }
                            }
                        } label: {
                            Label("Display", systemImage: "display")
                        }
                        Button { } label: { Image(systemName: "keyboard") }
                        Button { model.sendClipboard() } label: { Image(systemName: "doc.on.clipboard") }
                        Button {} label: { Image(systemName: "speaker.slash") }
                            .disabled(true)
                            .accessibilityLabel("Audio unavailable in this build")
                        Button { model.showSettings = true } label: { Image(systemName: "ellipsis") }
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.top, 16)
                    .padding(.horizontal, 20)
                    Spacer()
                }
                .transition(.opacity)
            }

            if showConnectionStats {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Text("\(Int(model.metrics.framesPerSecond)) FPS")
                        Text(String(format: "%.1f Mbps", Double(model.metrics.bitrate) / 1_000_000))
                        Text(String(format: "RTT %.1f ms", model.metrics.rttMilliseconds))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.bottom, 18)
                }
            }
        }
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .sheet(isPresented: $model.showSettings) { iPadSettingsView() }
    }

    private var statusText: String {
        switch model.connectionState {
        case .connecting: "Connecting to \(model.selectedHostName)…"
        case .pairing: "Confirm pairing"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case let .unavailable(reason): reason
        case .idle: "Disconnected"
        }
    }

    private func revealControls() {
        withAnimation(NuboDesign.quietAnimation) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(NuboDesign.quietAnimation) { controlsVisible = false }
        }
    }
}

private struct RemoteVideoSurface: UIViewRepresentable {
    let mailbox: LatestFrameMailbox

    func makeUIView(context: Context) -> MetalVideoView {
        MetalVideoView(mailbox: mailbox)
    }

    func updateUIView(_ uiView: MetalVideoView, context: Context) {}
}
