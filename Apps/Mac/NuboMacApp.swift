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
                .frame(width: 640, height: 520)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.didFinishOnboarding ? .suppressed : .presented)

        MenuBarExtra("Nubo", systemImage: model.isReady ? "display.and.arrow.down" : "display.trianglebadge.exclamationmark") {
            NuboMenu(model: model)
        }

        Settings {
            MacSettingsView(model: model)
                .frame(width: 460, height: 280)
        }
    }
}
