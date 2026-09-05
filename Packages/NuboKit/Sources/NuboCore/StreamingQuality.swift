import Foundation

/// Pixel budget for the actual client surface, independent of Bonjour and display points.
public enum StreamingQuality {
    public static func configuration(quality: String, pixelWidth: Int, pixelHeight: Int, frameRate: String) -> StreamConfiguration {
        let width = max(960, pixelWidth)
        let height = max(600, pixelHeight)
        let limit: Double
        switch quality {
        case "native": limit = 3_840
        case "high": limit = 3_200
        case "balanced": limit = 2_560
        case "low": limit = 1_440
        default: limit = 3_200
        }
        let factor = min(1, limit / Double(max(width, height)))
        let targetWidth = max(2, Int(Double(width) * factor) & ~1)
        let targetHeight = max(2, Int(Double(height) * factor) & ~1)
        let fps = frameRate == "30" || (quality == "low" && frameRate == "automatic") ? 30 : 60
        let bitsPerPixel = quality == "native" || quality == "high" ? 0.14 : 0.10
        let bitrate = min(45_000_000, max(5_000_000, Int(Double(targetWidth * targetHeight * fps) * bitsPerPixel)))
        return .init(width: targetWidth, height: targetHeight, framesPerSecond: fps, bitrate: bitrate)
    }
}
