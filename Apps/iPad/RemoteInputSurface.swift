import NuboProtocol
import SwiftUI
import UIKit

struct RemoteInputSurface: UIViewRepresentable {
    let onEvent: @Sendable (NuboMessage) -> Void

    func makeUIView(context: Context) -> InputCaptureView {
        let view = InputCaptureView()
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ uiView: InputCaptureView, context: Context) {
        uiView.onEvent = onEvent
    }
}

final class InputCaptureView: UIView, UIGestureRecognizerDelegate {
    var onEvent: (@Sendable (NuboMessage) -> Void)?
    private var lastPanTranslation = CGPoint.zero
    private var lastScrollTranslation = CGPoint.zero
    private var lastHoverLocation: CGPoint?
    private var lastDragLocation = CGPoint.zero
    private var isDraggingRemotely = false

    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        let pointerPan = UIPanGestureRecognizer(target: self, action: #selector(pointerPan(_:)))
        pointerPan.maximumNumberOfTouches = 1
        addGestureRecognizer(pointerPan)

        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragChanged(_:)))
        drag.minimumPressDuration = 0.22
        drag.allowableMovement = .greatestFiniteMagnitude
        drag.delegate = self
        addGestureRecognizer(drag)

        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        addGestureRecognizer(scrollPan)

        let click = UITapGestureRecognizer(target: self, action: #selector(leftClick))
        click.buttonMaskRequired = .primary
        addGestureRecognizer(click)

        let twoFingerClick = UITapGestureRecognizer(target: self, action: #selector(rightClick))
        twoFingerClick.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerClick)

        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(rightClick))
        secondaryClick.buttonMaskRequired = .secondary
        addGestureRecognizer(secondaryClick)

        let doubleClick = UITapGestureRecognizer(target: self, action: #selector(doubleClick))
        doubleClick.numberOfTapsRequired = 2
        doubleClick.buttonMaskRequired = .primary
        addGestureRecognizer(doubleClick)
        click.require(toFail: doubleClick)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        addGestureRecognizer(hover)

        addInteraction(UIPointerInteraction(delegate: nil))
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        presses.forEach { sendKey($0, isDown: true) }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        presses.forEach { sendKey($0, isDown: false) }
        super.pressesEnded(presses, with: event)
    }

    @objc private func pointerPan(_ recognizer: UIPanGestureRecognizer) {
        guard !isDraggingRemotely else { return }
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began { lastPanTranslation = .zero }
        let delta = Vector(dx: translation.x - lastPanTranslation.x, dy: translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        onEvent?(.pointer(.relativeMotion(delta)))
    }

    @objc private func dragChanged(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            isDraggingRemotely = true
            lastDragLocation = location
            onEvent?(.pointer(.button(.left, .down, clickCount: 1)))
        case .changed:
            let delta = Vector(dx: location.x - lastDragLocation.x, dy: location.y - lastDragLocation.y)
            lastDragLocation = location
            onEvent?(.pointer(.relativeMotion(delta)))
        case .ended, .cancelled, .failed:
            if isDraggingRemotely { onEvent?(.pointer(.button(.left, .up, clickCount: 1))) }
            isDraggingRemotely = false
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UILongPressGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer
    }

    @objc private func scrollPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began { lastScrollTranslation = .zero }
        let delta = Vector(dx: translation.x - lastScrollTranslation.x, dy: translation.y - lastScrollTranslation.y)
        lastScrollTranslation = translation
        onEvent?(.pointer(.scroll(delta, isPrecise: true)))
    }

    @objc private func hoverMoved(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: self)
        defer { lastHoverLocation = recognizer.state == .ended ? nil : location }
        guard let previous = lastHoverLocation else { return }
        onEvent?(.pointer(.relativeMotion(Vector(dx: location.x - previous.x, dy: location.y - previous.y))))
    }

    @objc private func leftClick() { click(.left) }
    @objc private func rightClick() { click(.right) }
    @objc private func doubleClick() {
        onEvent?(.pointer(.button(.left, .down, clickCount: 2)))
        onEvent?(.pointer(.button(.left, .up, clickCount: 2)))
    }

    private func click(_ button: MouseButton) {
        onEvent?(.pointer(.button(button, .down, clickCount: 1)))
        onEvent?(.pointer(.button(button, .up, clickCount: 1)))
    }

    private func sendKey(_ press: UIPress, isDown: Bool) {
        guard let key = press.key else { return }
        let modifiers = KeyModifiers(uiFlags: key.modifierFlags)
        onEvent?(.key(KeyInputEvent(
            hidUsage: UInt16(clamping: key.keyCode.rawValue),
            characters: key.charactersIgnoringModifiers,
            isDown: isDown,
            isRepeat: press.phase == .changed,
            modifiers: modifiers
        )))
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
