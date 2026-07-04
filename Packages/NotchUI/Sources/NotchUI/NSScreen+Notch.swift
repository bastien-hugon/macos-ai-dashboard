import AppKit
import CoreGraphics

extension NSScreen {
    /// Taille du notch physique (05 · REQ-NUI-12) : hauteur = `safeAreaInsets.top`,
    /// largeur = frame − zones auxiliaires. `.zero` si l'écran n'a pas de découpe.
    public var notchSize: CGSize {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return .zero }
        let width = frame.width - left.width - right.width
        guard width > 0 else { return .zero }
        return CGSize(width: width, height: safeAreaInsets.top)
    }

    public var hasNotch: Bool { notchSize != .zero }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    public var isBuiltinDisplay: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Identifiant stable d'écran (05 · REQ-NUI-14), survit aux reconnexions.
    public var displayUUID: String? {
        guard let id = displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Hauteur de la barre de menus de cet écran (0 si masquée).
    public var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}
