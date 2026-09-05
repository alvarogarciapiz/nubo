import SwiftUI

struct iPadSettingsView: View {
    @AppStorage("matchDesktopViewport") private var matchDesktopViewport = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("streamingQuality") private var streamingQuality = "automatic"
    @AppStorage("frameRate") private var frameRate = "automatic"
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.0
    @AppStorage("trackpadGestures") private var trackpadGestures = true
    @AppStorage("clipboardSync") private var clipboardSync = true
    @AppStorage("showConnectionStats") private var showConnectionStats = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $streamingQuality) {
                        Text("Automatic").tag("automatic")
                        Text("Maximum Detail").tag("native")
                        Text("High").tag("high")
                        Text("Balanced").tag("balanced")
                        Text("Low").tag("low")
                    }
                    Picker("Frame Rate", selection: $frameRate) {
                        Text("Automatic").tag("automatic")
                        Text("60 FPS").tag("60")
                        Text("30 FPS").tag("30")
                    }
                } header: {
                    Text("Streaming")
                } footer: {
                    Text("Automatic matches this iPad’s pixels. Maximum Detail requests up to 4K from your Mac and uses more bandwidth.")
                }

                Section("Input") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Touch Pointer Speed") {
                            Text(String(format: "%.1f×", pointerSpeed))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $pointerSpeed, in: 0.25...2.5)
                    }
                    .padding(.vertical, 4)
                    Toggle("Trackpad Gestures", isOn: $trackpadGestures)
                }
                Section {
                    Toggle("Match Mac Desktop to iPad", isOn: $matchDesktopViewport)
                } footer: {
                    Text("Changes the physical Mac display to its closest supported resolution. Other people at the Mac will see this change. Restores the original mode on disconnect; arbitrary virtual-display sizes are not supported.")
                }

                Section {
                    Text("One finger moves the cursor. Tap to click, tap twice to double-click. Hold and move to drag. Two fingers scroll; a two-finger tap right-clicks. Pinch to zoom. Tap with three fingers to show controls.")
                        .foregroundStyle(.secondary)
                    Text("Some shortcuts belong to iPadOS. Use the session’s More menu to send Spotlight, Switch App, Close Window and Quit App directly to your Mac.")
                        .foregroundStyle(.secondary)
                } header: { Text("Gestures & Shortcuts") }

                Section("Session") {
                    Toggle("Clipboard Sync", isOn: $clipboardSync)
                    LabeledContent("Audio") {
                        Text("Coming later")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Show Connection Stats", isOn: $showConnectionStats)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Shows live frame rate, bitrate and round-trip time during a session.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
