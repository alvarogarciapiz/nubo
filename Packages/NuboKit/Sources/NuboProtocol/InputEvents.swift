import Foundation

public struct Point: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Vector: Codable, Equatable, Sendable {
    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public enum MouseButton: UInt8, Codable, Hashable, Sendable {
    case left, right, middle, auxiliary
}

public enum ButtonPhase: UInt8, Codable, Sendable {
    case down, up
}

public enum PointerEvent: Codable, Equatable, Sendable {
    case relativeMotion(Vector)
    case absoluteMotion(Point)
    case button(MouseButton, ButtonPhase, clickCount: Int)
    case scroll(Vector, isPrecise: Bool)
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)
}

public struct KeyInputEvent: Codable, Equatable, Sendable {
    public let hidUsage: UInt16
    public let characters: String?
    public let isDown: Bool
    public let isRepeat: Bool
    public let modifiers: KeyModifiers

    public init(hidUsage: UInt16, characters: String?, isDown: Bool, isRepeat: Bool, modifiers: KeyModifiers) {
        self.hidUsage = hidUsage
        self.characters = characters
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.modifiers = modifiers
    }
}
