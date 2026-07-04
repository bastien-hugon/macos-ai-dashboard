import AppKit
import DashCore

/// Géométrie de la surface notch d'un écran donné (05 · §3.1).
public struct NotchGeometry: Equatable, Sendable {
    public let screenUUID: String
    public let hasPhysicalNotch: Bool
    public let notchSize: CGSize
    public let menuBarHeight: CGFloat

    /// Largeur de repos de la fausse encoche sur écran externe (05 · REQ-NUI-13)
    /// [HYPOTHÈSE — à calibrer visuellement].
    public static let externalPillWidth: CGFloat = 190
    public static let shadowPadding: CGFloat = 20
    public static let overshootBleed: CGFloat = 50 // REQ-NUI-47

    public init(screenUUID: String, hasPhysicalNotch: Bool, notchSize: CGSize, menuBarHeight: CGFloat) {
        self.screenUUID = screenUUID
        self.hasPhysicalNotch = hasPhysicalNotch
        self.notchSize = notchSize
        self.menuBarHeight = menuBarHeight
    }

    @MainActor
    public init?(screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return nil }
        let notch = screen.notchSize
        self.init(
            screenUUID: uuid,
            hasPhysicalNotch: notch != .zero,
            notchSize: notch,
            menuBarHeight: screen.menuBarHeight
        )
    }

    /// Taille de repos du pill : notch physique + débord de 4 pt (2 pt de chaque côté,
    /// REQ-NUI-12), ou fausse encoche 190 × hauteur de barre de menus (plancher 24 pt).
    public var pillRestSize: CGSize {
        if hasPhysicalNotch {
            return CGSize(width: notchSize.width + 4, height: notchSize.height)
        }
        return CGSize(width: Self.externalPillWidth, height: max(menuBarHeight, 24))
    }

    /// Largeur d'une aile du pill selon le mode (REQ-NUI-27) [HYPOTHÈSE — à calibrer].
    /// `.auto` retourne la largeur nécessaire au contenu M0 (avatar + compteur).
    public func wingWidth(mode: PillWidthMode) -> CGFloat {
        switch mode {
        case .auto: 56
        case .wide: 60
        case .ultraWide: 100
        }
    }
}
