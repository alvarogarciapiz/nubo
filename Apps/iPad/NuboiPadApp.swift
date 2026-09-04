import SwiftUI

@main
struct NuboiPadApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = iPadAppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    model.handleScenePhase(phase)
                }
        }
    }
}
