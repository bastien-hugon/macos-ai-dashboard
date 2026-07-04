import AppKit
import DashCore
import NotchUI
import SwiftUI

/// Barre de menus (06) : `NSStatusItem` variableLength + `NSHostingView`, clic gauche →
/// popover transient (sans activer l'app), clic droit → menu Quit.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let sessions: SessionStore
    private let usage: UsageStore
    private let servers: ServerStore
    private let settings: SettingsStore
    private let onRefreshUsage: () -> Void
    private let onStopServer: (DevServer) -> Void
    private let onOpenSettings: () -> Void

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    init(sessions: SessionStore, usage: UsageStore, servers: ServerStore, settings: SettingsStore,
         onRefreshUsage: @escaping () -> Void, onStopServer: @escaping (DevServer) -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.sessions = sessions
        self.usage = usage
        self.servers = servers
        self.settings = settings
        self.onRefreshUsage = onRefreshUsage
        self.onStopServer = onStopServer
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let label = MenuBarLabel(sessions: sessions, usage: usage, showsUsage: settings.menuBarShowsUsage)
        let hosting = NSHostingView(rootView: label)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.setAccessibilityLabel("AgentDash")
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func uninstall() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            showQuitMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func showQuitMenu(_ button: NSStatusBarButton) {
        // Menu assigné temporairement puis retiré (REQ-MBR-11) : le clic gauche ne l'ouvre jamais.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit AgentDash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let content = MenuBarPopover(
            sessions: sessions, usage: usage, servers: servers, settings: settings,
            onRefreshUsage: onRefreshUsage,
            onStopServer: onStopServer,
            onOpenSettings: { [weak self] in self?.popover.performClose(nil); self?.onOpenSettings() }
        )
        popover.contentViewController = NSHostingController(rootView: content)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Ne pas activer l'app (REQ-MBR-13) : le popover transient reste sans vol de focus.
    }
}
