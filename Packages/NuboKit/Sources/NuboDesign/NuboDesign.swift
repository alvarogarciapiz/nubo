import SwiftUI

public enum NuboDesign {
    public static let smallRadius: CGFloat = 8
    public static let radius: CGFloat = 10
    public static let border = Color.primary.opacity(0.10)
    public static let secondaryFill = Color.primary.opacity(0.045)
    public static let quietAnimation = Animation.easeInOut(duration: 0.2)
}

public struct NuboRowStyle: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(NuboDesign.secondaryFill)
            .clipShape(RoundedRectangle(cornerRadius: NuboDesign.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: NuboDesign.radius, style: .continuous)
                    .stroke(NuboDesign.border, lineWidth: 1)
            }
    }
}

public extension View {
    func nuboRowStyle() -> some View { modifier(NuboRowStyle()) }
}
