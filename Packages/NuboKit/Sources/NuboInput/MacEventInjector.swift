#if os(macOS)
import AppKit
import CoreGraphics
import NuboCore
import NuboProtocol

public actor MacEventInjector {
    private var cursorPosition: CGPoint
    private var pressedButtons: Set<MouseButton> = []
    private var pressedKeys: Set<CGKeyCode> = []
    private var scrollRemainder = Vector(dx: 0, dy: 0)

    public init(initialCursorPosition: CGPoint? = nil) {
        cursorPosition = initialCursorPosition ?? CGEvent(source: nil)?.location ?? .zero
    }

    public func inject(_ event: PointerEvent) {
        switch event {
        case let .relativeMotion(delta):
            cursorPosition = CGEvent(source: nil)?.location ?? cursorPosition
            cursorPosition.x += delta.dx
            cursorPosition.y += delta.dy
            let type: CGEventType = pressedButtons.contains(.left) ? .leftMouseDragged : (pressedButtons.contains(.right) ? .rightMouseDragged : .mouseMoved)
            postMouse(type: type, button: pressedButtons.contains(.right) ? .right : .left, at: cursorPosition)
        case let .absoluteMotion(point):
            guard point.x.isFinite, point.y.isFinite else { return }
            cursorPosition = CGPoint(x: point.x, y: point.y)
            let type: CGEventType = pressedButtons.contains(.left) ? .leftMouseDragged : (pressedButtons.contains(.right) ? .rightMouseDragged : .mouseMoved)
            postMouse(type: type, button: pressedButtons.contains(.right) ? .right : .left, at: cursorPosition)
        case let .button(button, phase, clickCount):
            postButton(button, phase: phase, clickCount: clickCount)
        case let .scroll(delta, precise):
            guard delta.dx.isFinite, delta.dy.isFinite else { return }
            let x = min(32_000, max(-32_000, delta.dx + scrollRemainder.dx))
            let y = min(32_000, max(-32_000, delta.dy + scrollRemainder.dy))
            scrollRemainder = .init(dx: x - x.rounded(.towardZero), dy: y - y.rounded(.towardZero))
            let source = CGEventSource(stateID: .hidSystemState)
            let units: CGScrollEventUnit = precise ? .pixel : .line
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: units,
                wheelCount: 2,
                wheel1: Int32(y),
                wheel2: Int32(x),
                wheel3: 0
            )
            event?.post(tap: .cghidEventTap)
        }
    }

    public func inject(_ event: KeyInputEvent) {
        guard let keyCode = HIDKeyMap.macVirtualKeyCode(for: event.hidUsage) else {
            if event.hidUsage == 0, let characters = event.characters, !characters.isEmpty {
                postUnicode(characters, isDown: event.isDown, modifiers: event.modifiers)
                return
            }
            NuboLog.input.debug("Unsupported HID usage: \(event.hidUsage)")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: event.isDown)
        keyEvent?.flags = flags(for: event.modifiers)
        keyEvent?.post(tap: .cghidEventTap)
        if event.isDown {
            pressedKeys.insert(keyCode)
        } else {
            pressedKeys.remove(keyCode)
        }
    }

    private func postUnicode(_ text: String, isDown: Bool, modifiers: KeyModifiers) {
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: 0,
            keyDown: isDown
        ) else { return }
        event.flags = flags(for: modifiers)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Prevents a cancelled network session from leaving a modifier or mouse
    /// button logically held down on the host.
    public func releaseAll() {
        for button in Array(pressedButtons) {
            postButton(button, phase: .up, clickCount: 1)
        }
        for keyCode in pressedKeys {
            CGEvent(
                keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                virtualKey: keyCode,
                keyDown: false
            )?.post(tap: .cghidEventTap)
        }
        pressedButtons.removeAll(keepingCapacity: true)
        pressedKeys.removeAll(keepingCapacity: true)
    }

    private func postButton(_ button: MouseButton, phase: ButtonPhase, clickCount: Int) {
        if phase == .down { pressedButtons.insert(button) }
        let cgButton: CGMouseButton
        let down: CGEventType
        let up: CGEventType
        switch button {
        case .left:
            cgButton = .left; down = .leftMouseDown; up = .leftMouseUp
        case .right:
            cgButton = .right; down = .rightMouseDown; up = .rightMouseUp
        case .middle, .auxiliary:
            cgButton = .center; down = .otherMouseDown; up = .otherMouseUp
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source, mouseType: phase == .down ? down : up, mouseCursorPosition: cursorPosition, mouseButton: cgButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.post(tap: .cghidEventTap)
        if phase == .up { pressedButtons.remove(button) }
    }

    private func postMouse(type: CGEventType, button: CGMouseButton, at point: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
#endif
