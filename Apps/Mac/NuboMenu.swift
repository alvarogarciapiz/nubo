import SwiftUI

struct NuboMenu: View {
    @Bindable var model: MacAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Nubo").font(.headline)

        Section("Status") {
            Label(model.connectedDeviceName == nil ? (model.isReady ? "Ready" : "Setup required") : "Connected", systemImage: "circle.fill")
                .symbolRenderingMode(.monochrome)
        }

        if let deviceName = model.connectedDeviceName {
            Section("Connected devices") {
                Text(deviceName)
                if let startedAt = model.sessionStartedAt {
                    Text(startedAt, style: .timer).monospacedDigit()
                }
            }
        }

        Divider()

        Toggle("Start at Login", isOn: Binding(
            get: { model.startAtLogin },
            set: { model.setStartAtLogin($0) }
        ))

        Button(model.didFinishOnboarding ? "Permissions…" : "Finish Setup…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "onboarding")
        }

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")

        Divider()
        Button("Quit Nubo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MacSettingsView: View {
    @Bindable var model: MacAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start Nubo at login", isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }
                ))
                LabeledContent("Status", value: model.isReady ? "Ready" : "Setup required")
                Button("Review Permissions…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "onboarding")
                }
            }

            Section("Network") {
                LabeledContent("Service port", value: "49832")
                LabeledContent("Discovery", value: "Bonjour")
            }

            Section {
                Text("Connections are authenticated and encrypted. Bonjour is used only to discover this Mac on the local network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
