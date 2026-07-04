import CoreGraphics
import Foundation
import Observation

/// État d'une surface notch (une par écran porteur) — 05 · §3.1.
@MainActor @Observable
public final class NotchViewModel {
    /// Machine à états d'expansion (05 · REQ-NUI-17, §3.3).
    public enum SurfaceState: Equatable, Sendable {
        case pill, opening, panel, closing
    }

    public enum KeyFocusOwner: Equatable, Sendable {
        case none, prompt, textField
    }

    public internal(set) var state: SurfaceState = .pill
    public var geometry: NotchGeometry
    public var isHoveringPill: Bool = false
    public var keyFocusOwner: KeyFocusOwner = .none
    /// Taille réellement rendue du panel ouvert (pour le hit-test du clic extérieur).
    public var panelRenderedSize: CGSize = .zero
    /// Hauteur naturelle mesurée du contenu du panel — pilote le vrai resize de la forme
    /// pendant l'ouverture (estimation initiale, affinée par preference dès le premier layout).
    public var panelContentHeight: CGFloat = 340

    public var isExpanded: Bool { state == .opening || state == .panel }

    public init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}
