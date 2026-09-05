import Foundation

public enum DisplayModeSelection {
    /// Favor aspect ratio first, then desktop point size. Never invent modes.
    public static func score(width: Int, height: Int, targetWidth: Int, targetHeight: Int) -> Double {
        guard min(width, height, targetWidth, targetHeight) > 0 else { return .infinity }
        let aspect = abs(log((Double(width) / Double(height)) / (Double(targetWidth) / Double(targetHeight))))
        let size = abs(log((Double(width) * Double(height)) / (Double(targetWidth) * Double(targetHeight))))
        return aspect * 4 + size
    }
}
