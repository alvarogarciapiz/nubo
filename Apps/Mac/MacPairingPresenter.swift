import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import NuboNetworking

@MainActor
final class MacPairingPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var completion: ((Bool) -> Void)?
    private var expiry: Task<Void, Never>?

    func present(peerName: String, code: String, completion: @escaping (Bool) -> Void) {
        finish(false)
        self.completion = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 530),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Pair iPad"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MacPairingView(peerName: peerName, code: code) { [weak self] accepted in
            self?.finish(accepted)
        })
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.finish(false)
        }
    }

    func windowWillClose(_ notification: Notification) { finish(false) }

    private func finish(_ accepted: Bool) {
        let callback = completion
        completion = nil
        expiry?.cancel()
        expiry = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        callback?(accepted)
    }
}

private struct MacPairingView: View {
    let peerName: String
    let code: String
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "ipad.and.arrow.forward")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text("Connect \(peerName)?")
                .font(.title2.weight(.semibold))
            Text("Enter this code on your iPad. Allow only a device you recognize.")
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 36, weight: .medium, design: .monospaced))
                .tracking(5)
                .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: ", "))")
            if let qrImage {
                HStack(spacing: 20) {
                    Image(nsImage: qrImage).interpolation(.none)
                        .resizable().frame(width: 144, height: 144)
                        .padding(8).background(.white)
                        .accessibilityLabel("QR code for this pairing attempt")
                    Text("Or scan this QR from Nubo on your iPad.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Expires in two minutes. This iPad will be remembered.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Button("Don’t Allow") { decide(false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow iPad") { decide(true) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 8))
        }
        .padding(28)
    }

    private var qrImage: NSImage? {
        guard let payload = PairingCode.qrPayload(for: code) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }
}
