import SwiftUI

public enum NuboDesign {
    public static let smallRadius: CGFloat = 8
    public static let radius: CGFloat = 12
    public static let controlRadius: CGFloat = 14
    public static let minimumHitTarget: CGFloat = 44
    public static let border = Color.primary.opacity(0.09)
    public static let quietAnimation = Animation.easeInOut(duration: 0.2)
}

public struct NuboControlSurface: ViewModifier {
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = NuboDesign.controlRadius) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(NuboDesign.border, lineWidth: 1)
                }
        }
    }
}

public extension View {
    func nuboControlSurface(cornerRadius: CGFloat = NuboDesign.controlRadius) -> some View {
        modifier(NuboControlSurface(cornerRadius: cornerRadius))
    }
}
