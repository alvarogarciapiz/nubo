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
        .sheet(isPresented: $model.showPairingConfirmation) {
            PairingCodeView(model: model)
        }
    }
}

private struct PairingCodeView: View {
    @Bindable var model: iPadAppModel
    @State private var code = ""
    @State private var scanning = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair with \(model.pairingPeerName)")
                        .font(.title2.weight(.semibold))
                    Text("Enter the six-digit code shown on your Mac, then allow the connection there.")
                        .foregroundStyle(.secondary)
                }
                TextField("000000", text: $code)
                    .font(.largeTitle.monospacedDigit())
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .accessibilityLabel("Six-digit pairing code")
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider() }
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    }
                if let error = model.pairingError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Text("You only need to do this once. The code expires after two minutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Pair Mac") { model.submitPairingCode(code) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .controlSize(.large)
                    .disabled(code.count != 6)
                Button { focused = false; scanning = true } label: {
                    Label("Scan QR on Mac", systemImage: "qrcode.viewfinder")
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.decidePairing(false) }
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.large])
        .onAppear { focused = true }
        .sheet(isPresented: $scanning) {
            PairingScannerView { scanned in
                scanning = false
                model.submitPairingCode(scanned)
            }
        }
    }
}

struct iPadOnboardingView: View {
    @Binding var didFinish: Bool
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nubo")
                    .font(.headline)
                Spacer()
                Text("\(page + 1) of 2")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)

            Group {
                if page == 0 {
                    welcome
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                } else {
                    preparation
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button(page == 0 ? "Get Started" : "Find My Mac") {
                withAnimation(reduceMotion ? nil : NuboDesign.quietAnimation) {
                    if page == 0 { page = 1 } else { didFinish = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .controlSize(.large)
            .frame(maxWidth: 360)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .accessibilityHidden(true)
            Text("Your Mac, anywhere.")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Control your Mac directly from your iPad.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Before you connect")
                    .font(.largeTitle.weight(.semibold))
                Text("Three things, then you’re connected.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                instruction("01", "Open Nubo on your Mac", detail: "Complete the guided permissions setup.")
                Divider().padding(.leading, 52)
                instruction("02", "Use the same network", detail: "Nubo discovers nearby Macs automatically.")
                Divider().padding(.leading, 52)
                instruction("03", "Pair your iPad", detail: "Type the code displayed on your Mac.")
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(32)
    }

    private func instruction(_ number: String, _ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(number)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 16)
    }
}
