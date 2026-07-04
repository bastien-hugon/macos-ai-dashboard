import AppKit
import DashCore
import SwiftUI

/// Fenêtre Settings redimensionnable (13 · §2.1). Ouvre/focalise une fenêtre unique ;
/// tant qu'elle est key, le notch reste ouvert (REQ-NUI-21, câblé via le coordinateur).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeRoot: () -> AnyView
    var onKeyChange: ((Bool) -> Void)?

    init(makeRoot: @escaping () -> AnyView) {
        self.makeRoot = makeRoot
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: makeRoot())
        let window = NSWindow(contentViewController: hosting)
        window.title = "AgentDash Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 720, height: 500))
        window.isReleasedWhenClosed = false
        window.center()
        // Suivi du statut key pour garder le notch ouvert.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onKeyChange?(true) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onKeyChange?(false) }
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
