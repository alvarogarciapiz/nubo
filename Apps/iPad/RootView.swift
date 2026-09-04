import NuboDesign
import NuboNetworking
import SwiftUI

struct RootView: View {
    @Bindable var model: iPadAppModel
    @AppStorage("didFinishiPadOnboarding") private var didFinishOnboarding = false

    var body: some View {
        Group {
            if didFinishOnboarding {
                NavigationStack(path: $model.path) {
                    HomeView(model: model)
                        .navigationDestination(for: ConnectionEndpoint.self) { _ in
                            SessionView(model: model)
                                .toolbar(.hidden, for: .navigationBar)
                        }
                }
            } else {
                iPadOnboardingView(didFinish: $didFinishOnboarding)
            }
        }
        .tint(.primary)
        .alert("Confirm pairing", isPresented: $model.showPairingConfirmation) {
            Button("Cancel", role: .cancel) { model.decidePairing(false) }
            Button("Codes Match") { model.decidePairing(true) }
        } message: {
            Text("Check that \(model.pairingPeerName) shows this code:\n\n\(model.pairingCode)")
        }
    }
}

struct iPadOnboardingView: View {
    @Binding var didFinish: Bool
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if page == 0 {
                VStack(spacing: 16) {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 34, weight: .medium))
                    Text("Nubo").font(.system(size: 44, weight: .semibold))
                    Text("Your Mac, anywhere.")
                        .font(.title2.weight(.medium))
                    Text("Control your Mac directly from your iPad.")
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Before you connect")
                        .font(.system(size: 32, weight: .semibold))
                    instruction("1", "Open Nubo on your Mac")
                    instruction("2", "Keep both devices on the same network")
                    instruction("3", "Select your Mac and confirm the pairing code")
                }
                .frame(maxWidth: 500, alignment: .leading)
                .transition(.opacity)
            }
            Spacer()
            Button(page == 0 ? "Get Started" : "Find My Mac") {
                withAnimation(NuboDesign.quietAnimation) {
                    if page == 0 { page = 1 } else { didFinish = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 54)
        }
        .padding(.horizontal, 36)
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(spacing: 18) {
            Text(number).font(.headline.monospacedDigit()).frame(width: 20)
            Text(text).font(.title3)
        }
    }
}
