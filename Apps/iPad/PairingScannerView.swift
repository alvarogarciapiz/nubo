import AVFoundation
import NuboNetworking
import SwiftUI
import VisionKit

struct PairingScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("Use the pairing code", systemImage: "camera", description: Text(error))
                } else if authorized {
                    ScannerSurface(onCode: onCode, onError: { error = $0 })
                } else {
                    ProgressView("Preparing camera…")
                }
            }
            .navigationTitle("Scan the QR on your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            guard DataScannerViewController.isSupported else {
                error = "QR scanning is not supported on this iPad. Enter the six-digit code instead."
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted, DataScannerViewController.isAvailable else {
                error = "Camera access is unavailable. Allow it in Settings or enter the code manually."
                return
            }
            authorized = true
        }
    }
}

private struct ScannerSurface: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> PairingScannerController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        let controller = PairingScannerController(scanner: scanner)
        controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: PairingScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: PairingScannerController, coordinator: Coordinator) {
        controller.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var completed = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !completed else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue,
                   let code = PairingCode.code(fromQR: payload) {
                    completed = true
                    dataScanner.stopScanning()
                    onCode(code)
                    return
                }
            }
        }
    }
}

private final class PairingScannerController: UIViewController {
    let scanner: DataScannerViewController
    var onError: ((String) -> Void)?
    init(scanner: DataScannerViewController) {
        self.scanner = scanner
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }
    func stopScanning() { scanner.stopScanning() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do { try scanner.startScanning() }
        catch { onError?("The camera could not start. Enter the six-digit code instead.") }
    }
    override func viewWillDisappear(_ animated: Bool) {
        stopScanning()
        super.viewWillDisappear(animated)
    }
}
