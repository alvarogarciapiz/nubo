import AppKit
import NuboDesign
import ServiceManagement
import SwiftUI

@main
struct NuboMacApp: App {
    @State private var model = MacAppModel()

    var body: some Scene {
        Window("Nubo", id: "onboarding") {
            MacOnboardingView(model: model)
                .frame(width: 720, height: 560)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.shouldPresentOnboardingAtLaunch ? .presented : .suppressed)

        MenuBarExtra {
            NuboMenu(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: NuboStatusIcon.image)
                if model.connectedDeviceName != nil {
                    Circle().fill(.green).frame(width: 5, height: 5)
                }
                if model.showsReadyConfirmation {
                    Text("Nubo is ready")
                }
            }
            .accessibilityLabel(model.connectedDeviceName.map { "Nubo, connected to \($0)" }
                ?? (model.isReady ? "Nubo, ready" : "Nubo, setup required"))
        }

        Settings {
            MacSettingsView(model: model)
                .frame(width: 480, height: 360)
        }
    }
}
