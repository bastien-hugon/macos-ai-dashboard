import DashCore
import SwiftUI

/// Interface « depth-lit » (05 · REQ-NUI-42) : cartes en relief (ombre externe basse +
/// lumière interne haute) et puits en creux (ombre interne simulée). Togglable via
/// `depthLitEnabled` ; sans effet quand désactivé (rendu plat).
extension View {
    /// Carte en relief : ombre portée + liseré de lumière en haut.
    func depthLitCard(_ enabled: Bool, cornerRadius: CGFloat = 12) -> some View {
        modifier(DepthLitCard(enabled: enabled, cornerRadius: cornerRadius))
    }

    /// Puits en creux (pour jauges/zones encastrées) : ombre interne simulée.
    func depthLitWell(_ enabled: Bool, cornerRadius: CGFloat = 6) -> some View {
        modifier(DepthLitWell(enabled: enabled, cornerRadius: cornerRadius))
    }
}

private struct DepthLitCard: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay(alignment: .top) {
                    // Lumière interne haute.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.14), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2) // ombre externe basse
        } else {
            content
        }
    }
}

private struct DepthLitWell: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay {
                    // Ombre interne simulée : liseré sombre en haut, clair en bas.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(colors: [.black.opacity(0.4), .white.opacity(0.06)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}
