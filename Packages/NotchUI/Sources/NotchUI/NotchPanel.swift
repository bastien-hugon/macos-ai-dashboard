import AppKit

/// Fenêtre de la surface notch (05 · REQ-NUI-01..08).
/// Panel non-activant : aucune interaction ne retire le statut actif à l'app frontale ;
/// il ne devient key que sur demande explicite (`becomesKeyOnlyIfNeeded`).
@MainActor
public final class NotchPanel: NSPanel {
    public override var canBecomeKey: Bool { true }   // REQ-NUI-02
    public override var canBecomeMain: Bool { false }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                              // l'ombre est rendue en SwiftUI (05 · §3.7)
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        appearance = NSAppearance(named: .darkAqua)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3) // REQ-NUI-03
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    /// Devient key pour router les frappes vers le panel, sans activer l'app (REQ-NUI-55).
    func makeKeyIfNeeded() {
        guard !isKeyWindow else { return }
        makeKey()
    }

    func resignKeyIfNeeded() {
        guard isKeyWindow else { return }
        resignKey()
        orderFrontRegardless()
    }
}
