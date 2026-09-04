import SwiftUI

struct iPadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("streamingQuality") private var streamingQuality = "automatic"
    @AppStorage("frameRate") private var frameRate = "automatic"
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.0
    @AppStorage("trackpadGestures") private var trackpadGestures = true
    @AppStorage("audio") private var audio = true
    @AppStorage("clipboardSync") private var clipboardSync = true
    @AppStorage("showConnectionStats") private var showConnectionStats = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Streaming Quality", selection: $streamingQuality) {
                    Text("Automatic").tag("automatic")
                    Text("High").tag("high")
                    Text("Balanced").tag("balanced")
                    Text("Low").tag("low")
                }
                Picker("Frame Rate", selection: $frameRate) {
                    Text("Automatic").tag("automatic")
                    Text("60 FPS").tag("60")
                    Text("30 FPS").tag("30")
                }
                LabeledContent("Pointer Speed") {
                    Slider(value: $pointerSpeed, in: 0.25...2.5)
                        .frame(width: 220)
                }
                Toggle("Trackpad Gestures", isOn: $trackpadGestures)
                Toggle("Audio (coming next)", isOn: $audio)
                    .disabled(true)
                Toggle("Clipboard Sync", isOn: $clipboardSync)
                Toggle("Show Connection Stats", isOn: $showConnectionStats)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
