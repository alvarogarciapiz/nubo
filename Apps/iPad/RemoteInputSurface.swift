import NuboProtocol
import NuboCore
import NuboInput
import SwiftUI
import UIKit

struct RemoteInputSurface: UIViewRepresentable {
    let pointerSpeed: Double
    let trackpadGesturesEnabled: Bool
    let keyboardRequest: Int
    let isActive: Bool
    let display: DisplayDescriptor?
    let zoom: CGFloat
    let onZoom: (CGFloat) -> Void
    let onRevealControls: () -> Void
    let onEvent: (NuboMessage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InputCaptureView {
        let view = InputCaptureView()
        view.pointerSpeed = pointerSpeed
        view.trackpadGesturesEnabled = trackpadGesturesEnabled
        view.onEvent = onEvent
        view.display = display
        view.zoom = zoom
        view.onZoom = onZoom
        view.onRevealControls = onRevealControls
        view.setCapturing(isActive)
        context.coordinator.lastKeyboardRequest = keyboardRequest
        return view
    }

    func updateUIView(_ uiView: InputCaptureView, context: Context) {
        uiView.onEvent = onEvent
        uiView.pointerSpeed = pointerSpeed
        uiView.trackpadGesturesEnabled = trackpadGesturesEnabled
        uiView.display = display
        uiView.zoom = zoom
        uiView.onZoom = onZoom
        uiView.onRevealControls = onRevealControls
        uiView.setCapturing(isActive)
        if context.coordinator.lastKeyboardRequest != keyboardRequest {
            context.coordinator.lastKeyboardRequest = keyboardRequest
            uiView.showSoftwareKeyboard()
        }
    }

    final class Coordinator {
        var lastKeyboardRequest = 0
    }
}

final class InputCaptureView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate, UIKeyInput {
    var onEvent: ((NuboMessage) -> Void)?
    var display: DisplayDescriptor?
    var zoom: CGFloat = 1
    var onZoom: ((CGFloat) -> Void)?
    var onRevealControls: (() -> Void)?
    private var pinchOrigin: CGFloat = 1
    private var pinching = false
    private var lastClickTime: TimeInterval = 0
    private var lastClickLocation = CGPoint.zero
    private var indirectButton: MouseButton?
    private var capturing = false
    var pointerSpeed = 1.0
    var trackpadGesturesEnabled = true {
        didSet {
            guard oldValue != trackpadGesturesEnabled else { return }
            scrollPan.isEnabled = trackpadGesturesEnabled
            twoFingerClick.isEnabled = trackpadGesturesEnabled
            deviceScroll.isEnabled = trackpadGesturesEnabled
        }
    }
    private var lastPanTranslation = CGPoint.zero
    private var lastScrollTranslation = CGPoint.zero
    private var lastDragLocation = CGPoint.zero
    private var isDraggingRemotely = false
    private var pressedKeys: [UInt16: KeyInputEvent] = [:]
    private let suppressedInputView = UIView(frame: .zero)
    private var allowsSoftwareKeyboard = false
    private lazy var scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
    private lazy var twoFingerClick = UITapGestureRecognizer(target: self, action: #selector(rightClick))
    private lazy var deviceScroll = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { allowsSoftwareKeyboard ? nil : suppressedInputView }
    var hasText: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let pointerPan = UIPanGestureRecognizer(target: self, action: #selector(pointerPan(_:)))
        pointerPan.maximumNumberOfTouches = 1
        pointerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pointerPan.delegate = self
        addGestureRecognizer(pointerPan)

        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragChanged(_:)))
        drag.minimumPressDuration = 0.22
        drag.allowableMovement = 10
        drag.numberOfTouchesRequired = 1
        drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        drag.delegate = self
        addGestureRecognizer(drag)

        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        scrollPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollPan.delegate = self
        addGestureRecognizer(scrollPan)

        deviceScroll.allowedTouchTypes = []
        deviceScroll.allowedScrollTypesMask = .all
        addGestureRecognizer(deviceScroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchChanged(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let reveal = UITapGestureRecognizer(target: self, action: #selector(revealControls))
        reveal.numberOfTouchesRequired = 3
        reveal.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(reveal)

        let click = UITapGestureRecognizer(target: self, action: #selector(leftClick))
        click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(click)

        twoFingerClick.numberOfTouchesRequired = 2
        twoFingerClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(twoFingerClick)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        addGestureRecognizer(hover)

        addInteraction(UIPointerInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseRemoteState()
            allowsSoftwareKeyboard = false
            resignFirstResponder()
        } else if capturing {
            becomeFirstResponder()
        }
    }

    func setCapturing(_ enabled: Bool) {
        guard capturing != enabled else { return }
        capturing = enabled
        if enabled {
            if window != nil { becomeFirstResponder() }
        } else {
            releaseRemoteState()
            allowsSoftwareKeyboard = false
            resignFirstResponder()
        }
    }

    func showSoftwareKeyboard() {
        allowsSoftwareKeyboard = true
        if isFirstResponder {
            reloadInputViews()
        } else {
            becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        presses.forEach { sendKey($0, isDown: true) }
        let unhandled = Set(presses.filter { $0.key == nil })
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        presses.forEach { sendKey($0, isDown: false) }
        let unhandled = Set(presses.filter { $0.key == nil })
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        presses.forEach { sendKey($0, isDown: false) }
        let unhandled = Set(presses.filter { $0.key == nil })
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        sendText(text, isDown: true)
        sendText(text, isDown: false)
    }

    func deleteBackward() {
        let event = KeyInputEvent(hidUsage: 0x2A, characters: nil, isDown: true, isRepeat: false, modifiers: [])
        onEvent?(.key(event))
        onEvent?(.key(.init(hidUsage: event.hidUsage, characters: nil, isDown: false, isRepeat: false, modifiers: [])))
    }

    @objc private func pointerPan(_ recognizer: UIPanGestureRecognizer) {
        guard !isDraggingRemotely else { return }
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began {
            lastPanTranslation = .zero
        }
        guard recognizer.state == .changed || recognizer.state == .began else { return }
        let delta = scaledVector(dx: translation.x - lastPanTranslation.x, dy: translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        sendMotion(delta)
    }

    @objc private func dragChanged(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            isDraggingRemotely = true
            lastDragLocation = location
            onEvent?(.pointer(.button(.left, .down, clickCount: 1)))
        case .changed:
            let delta = scaledVector(dx: location.x - lastDragLocation.x, dy: location.y - lastDragLocation.y)
            lastDragLocation = location
            sendMotion(delta)
        case .ended, .cancelled, .failed:
            if isDraggingRemotely { onEvent?(.pointer(.button(.left, .up, clickCount: 1))) }
            isDraggingRemotely = false
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let dragAndPan = (gestureRecognizer is UILongPressGestureRecognizer && (otherGestureRecognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1)
            || (otherGestureRecognizer is UILongPressGestureRecognizer && (gestureRecognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1)
        let pinchAndPan = (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
            || (otherGestureRecognizer is UIPinchGestureRecognizer && gestureRecognizer is UIPanGestureRecognizer)
        return dragAndPan || pinchAndPan
    }

    @objc private func scrollPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        guard !pinching else { lastScrollTranslation = translation; return }
        if recognizer.state == .began {
            lastScrollTranslation = .zero
        }
        guard recognizer.state == .changed || recognizer.state == .began else { return }
        let delta = Vector(dx: translation.x - lastScrollTranslation.x, dy: translation.y - lastScrollTranslation.y)
        lastScrollTranslation = translation
        if delta.dx != 0 || delta.dy != 0 {
            onEvent?(.pointer(.scroll(delta, isPrecise: true)))
        }
    }

    @objc private func hoverMoved(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: self)
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        _ = sendAbsolute(location)
    }

    @objc private func leftClick(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        let now = CACurrentMediaTime()
        let isDouble = now - lastClickTime < 0.35 && hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y) < 24
        lastClickTime = isDouble ? 0 : now
        lastClickLocation = location
        let count = isDouble ? 2 : 1
        onEvent?(.pointer(.button(.left, .down, clickCount: count)))
        onEvent?(.pointer(.button(.left, .up, clickCount: count)))
    }
    @objc private func rightClick() { click(.right) }

    @objc private func revealControls() { onRevealControls?() }

    @objc private func pinchChanged(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began { pinchOrigin = zoom }
        if recognizer.state == .changed, pinching || abs(recognizer.scale - 1) > 0.06 {
            pinching = true
            zoom = min(3, max(1, pinchOrigin * recognizer.scale))
            onZoom?(zoom)
        }
        if [.ended, .cancelled, .failed].contains(recognizer.state) { pinching = false }
    }

    private func sendAbsolute(_ location: CGPoint) -> Bool {
        guard let display, let point = CoordinateMapper(display: display).desktopPoint(
            viewPoint: .init(x: location.x, y: location.y), viewportWidth: bounds.width, viewportHeight: bounds.height, zoom: zoom
        ) else { return false }
        onEvent?(.pointer(.absoluteMotion(point)))
        return true
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        nil // Keep the native local pointer responsive, independent of video RTT.
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer || $0.type == .pencil }), sendAbsolute(touch.location(in: self)) else {
            super.touchesBegan(touches, with: event); return
        }
        let button: MouseButton
        if event?.buttonMask.contains(.secondary) == true { button = .right }
        else if (event?.buttonMask.rawValue ?? 0) & 4 != 0 { button = .middle }
        else { button = .left }
        indirectButton = button
        onEvent?(.pointer(.button(button, .down, clickCount: max(1, touch.tapCount))))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first(where: { $0.type == .indirectPointer || $0.type == .pencil }) {
            _ = sendAbsolute(touch.location(in: self))
        } else { super.touchesMoved(touches, with: event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let button = indirectButton {
            onEvent?(.pointer(.button(button, .up, clickCount: max(1, touches.first?.tapCount ?? 1))))
            indirectButton = nil
        } else { super.touchesEnded(touches, with: event) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let button = indirectButton {
            onEvent?(.pointer(.button(button, .up, clickCount: 1)))
            indirectButton = nil
        }
        super.touchesCancelled(touches, with: event)
    }

    override var keyCommands: [UIKeyCommand]? {
        [("w", "Close Mac Window"), ("q", "Quit Mac App"), (" ", "Mac Spotlight"), ("\t", "Switch Mac App"),
         ("c", "Copy on Mac"), ("v", "Paste on Mac"), ("x", "Cut on Mac"), ("a", "Select All on Mac")].map { input, title in
            let command = UIKeyCommand(input: input, modifierFlags: .command, action: #selector(remoteCommand(_:)))
            command.discoverabilityTitle = title
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func remoteCommand(_ command: UIKeyCommand) {
        let usages: [String: UInt16] = ["w": 0x1A, "q": 0x14, " ": 0x2C, "\t": 0x2B, "c": 0x06, "v": 0x19, "x": 0x1B, "a": 0x04]
        guard let input = command.input, let usage = usages[input], pressedKeys[usage] == nil else { return }
        onEvent?(.key(.init(hidUsage: usage, characters: nil, isDown: true, isRepeat: false, modifiers: .command)))
        onEvent?(.key(.init(hidUsage: usage, characters: nil, isDown: false, isRepeat: false, modifiers: [])))
    }
    private func click(_ button: MouseButton) {
        onEvent?(.pointer(.button(button, .down, clickCount: 1)))
        onEvent?(.pointer(.button(button, .up, clickCount: 1)))
    }

    private func sendKey(_ press: UIPress, isDown: Bool) {
        guard let key = press.key else { return }
        let modifiers = KeyModifiers(uiFlags: key.modifierFlags)
        let event = KeyInputEvent(
            hidUsage: UInt16(clamping: key.keyCode.rawValue),
            characters: key.charactersIgnoringModifiers,
            isDown: isDown,
            isRepeat: press.phase == .changed,
            modifiers: modifiers
        )
        if isDown {
            pressedKeys[event.hidUsage] = event
        } else {
            pressedKeys.removeValue(forKey: event.hidUsage)
        }
        onEvent?(.key(event))
    }

    private func sendText(_ text: String, isDown: Bool) {
        onEvent?(.key(.init(
            hidUsage: 0,
            characters: text,
            isDown: isDown,
            isRepeat: false,
            modifiers: []
        )))
    }

    private func scaledVector(dx: CGFloat, dy: CGFloat) -> Vector {
        let scale = min(max(pointerSpeed, 0.25), 2.5)
        return Vector(dx: Double(dx) * scale, dy: Double(dy) * scale)
    }

    private func sendMotion(_ delta: Vector) {
        guard delta.dx != 0 || delta.dy != 0 else { return }
        onEvent?(.pointer(.relativeMotion(delta)))
    }

    private func releaseRemoteState() {
        if let button = indirectButton {
            onEvent?(.pointer(.button(button, .up, clickCount: 1)))
            indirectButton = nil
        }
        if isDraggingRemotely {
            onEvent?(.pointer(.button(.left, .up, clickCount: 1)))
            isDraggingRemotely = false
        }
        for event in pressedKeys.values {
            onEvent?(.key(.init(
                hidUsage: event.hidUsage,
                characters: event.characters,
                isDown: false,
                isRepeat: false,
                modifiers: []
            )))
        }
        pressedKeys.removeAll(keepingCapacity: true)
    }
}

private extension KeyModifiers {
    init(uiFlags: UIKeyModifierFlags) {
        var result: KeyModifiers = []
        if uiFlags.contains(.command) { result.insert(.command) }
        if uiFlags.contains(.alternate) { result.insert(.option) }
        if uiFlags.contains(.control) { result.insert(.control) }
        if uiFlags.contains(.shift) { result.insert(.shift) }
        if uiFlags.contains(.alphaShift) { result.insert(.capsLock) }
        self = result
    }
}
