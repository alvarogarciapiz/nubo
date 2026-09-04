import Foundation
import NuboCore
import NuboProtocol

public struct DesktopBounds: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public init(displays: [DisplayDescriptor]) {
        minX = displays.map(\.originX).min() ?? 0
        minY = displays.map(\.originY).min() ?? 0
        maxX = displays.map { $0.originX + Double($0.pixelWidth) / $0.scale }.max() ?? 0
        maxY = displays.map { $0.originY + Double($0.pixelHeight) / $0.scale }.max() ?? 0
    }
}

public struct CoordinateMapper: Sendable {
    private let display: DisplayDescriptor

    public init(display: DisplayDescriptor) {
        self.display = display
    }

    public func desktopPoint(normalized point: Point) -> Point {
        let x = min(max(point.x, 0), 1)
        let y = min(max(point.y, 0), 1)
        let pointWidth = Double(display.pixelWidth) / display.scale
        let pointHeight = Double(display.pixelHeight) / display.scale
        return Point(
            x: display.originX + x * pointWidth,
            y: display.originY + y * pointHeight
        )
    }

    public func scaledRelativeMotion(_ vector: Vector, sensitivity: Double) -> Vector {
        let clampedSensitivity = min(max(sensitivity, 0.1), 4)
        return Vector(dx: vector.dx * clampedSensitivity, dy: vector.dy * clampedSensitivity)
    }
}
