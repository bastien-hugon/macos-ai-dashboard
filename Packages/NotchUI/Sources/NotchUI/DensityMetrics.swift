import DashCore
import SwiftUI

/// Table unique des métriques par densité (05 · REQ-NUI-37) — aucune valeur en dur
/// dans les vues. Valeurs [HYPOTHÈSE — à calibrer visuellement].
public struct DensityMetrics: Sendable {
    public let rowHeight: CGFloat
    public let sectionSpacing: CGFloat
    public let cardPadding: CGFloat
    public let avatarSide: CGFloat
    public let titleFont: Font
    public let bodyFont: Font
    public let metricFont: Font

    public static func metrics(for density: Density, titleWeight: TitleWeight) -> DensityMetrics {
        let weight: Font.Weight = switch titleWeight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        return switch density {
        case .compact:
            DensityMetrics(
                rowHeight: 40, sectionSpacing: 8, cardPadding: 8, avatarSide: 20,
                titleFont: .system(size: 12, weight: weight),
                bodyFont: .system(size: 11),
                metricFont: .system(size: 10, design: .monospaced)
            )
        case .regular:
            DensityMetrics(
                rowHeight: 52, sectionSpacing: 10, cardPadding: 10, avatarSide: 24,
                titleFont: .system(size: 13, weight: weight),
                bodyFont: .system(size: 12),
                metricFont: .system(size: 11, design: .monospaced)
            )
        case .colossal:
            DensityMetrics(
                rowHeight: 64, sectionSpacing: 14, cardPadding: 14, avatarSide: 32,
                titleFont: .system(size: 15, weight: weight),
                bodyFont: .system(size: 14),
                metricFont: .system(size: 13, design: .monospaced)
            )
        }
    }
}

/// Couleurs d'état (05 · §4.5) [HYPOTHÈSE — à calibrer].
public extension SessionState {
    var tint: Color {
        switch self {
        case .executing: Color(red: 0.30, green: 0.85, blue: 0.45)
        case .thinking: Color(red: 0.35, green: 0.65, blue: 0.95)
        case .waiting: Color(red: 1.00, green: 0.72, blue: 0.20)
        case .idle: Color(white: 0.55)
        case .ended: Color(white: 0.35)
        }
    }
}
