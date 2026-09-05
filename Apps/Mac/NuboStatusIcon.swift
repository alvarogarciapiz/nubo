import AppKit

@MainActor
enum NuboStatusIcon {
    /// Vector approximation of the app artwork's outer cloud silhouette.
    static let image: NSImage = {
        let image = NSImage(size: .init(width: 19, height: 17), flipped: true) { rect in
            let path = NSBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                .init(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
            }
            path.move(to: p(0.20, 0.22))
            path.curve(to: p(0.66, 0.12), controlPoint1: p(0.25, -0.04), controlPoint2: p(0.54, -0.06))
            path.curve(to: p(0.92, 0.40), controlPoint1: p(0.86, 0.07), controlPoint2: p(0.98, 0.25))
            path.curve(to: p(0.80, 0.82), controlPoint1: p(1.09, 0.56), controlPoint2: p(0.99, 0.81))
            path.curve(to: p(0.36, 0.89), controlPoint1: p(0.74, 1.05), controlPoint2: p(0.48, 1.07))
            path.curve(to: p(0.06, 0.61), controlPoint1: p(0.15, 0.98), controlPoint2: p(-0.02, 0.82))
            path.curve(to: p(0.20, 0.22), controlPoint1: p(-0.09, 0.47), controlPoint2: p(0.03, 0.28))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
