import AppKit
import NuboCore

@MainActor
final class DesktopResolutionController: NSObject {
    private var originals: [CGDirectDisplayID: CGDisplayMode] = [:]
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(restore), name: NSApplication.willTerminateNotification, object: nil)
    }

    func fit(displayID: CGDirectDisplayID, width: Int, height: Int) -> String {
        guard (320...4096).contains(width), (320...4096).contains(height),
              let current = CGDisplayCopyDisplayMode(displayID),
              let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              let best = modes.filter({ $0.isUsableForDesktopGUI() }).min(by: {
                  DisplayModeSelection.score(width: $0.width, height: $0.height, targetWidth: width, targetHeight: height)
                    < DisplayModeSelection.score(width: $1.width, height: $1.height, targetWidth: width, targetHeight: height)
              }) else { return "This display does not offer compatible desktop modes." }
        if best.ioDisplayModeID != current.ioDisplayModeID {
            if originals[displayID] == nil { originals[displayID] = current }
            let result = CGDisplaySetDisplayMode(displayID, best, nil)
            guard result == .success else { return "macOS refused the resolution change (\(result.rawValue)). Keeping the current desktop." }
        }
        return "Desktop: \(best.width) × \(best.height) points. Closest mode supported by this Mac display; restored when you disconnect."
    }

    @objc func restore() {
        for (display, mode) in originals {
            if CGDisplaySetDisplayMode(display, mode, nil) == .success { originals.removeValue(forKey: display) }
        }
    }
}
