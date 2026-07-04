import AppKit
import DashCore
import SwiftUI

/// Coordinateur des surfaces notch (05 · §3.1/3.6) : possède les fenêtres (une par écran
/// porteur), la machine à états d'expansion et la reconfiguration multi-écrans.
@MainActor
public final class NotchSurfaceCoordinator {
    public enum OpenReason: Sendable { case hover, click, attention, settingsMirror }
    public enum CloseReason: Sendable { case hoverExit, clickOutside, clickNotch, programmatic }

    private struct Surface {
        let panel: NotchPanel
        let vm: NotchViewModel
    }

    private let sessions: SessionStore
    private let prompts: PromptStore
    private let usage: UsageStore
    private let settings: SettingsStore
    private let sections: @MainActor () -> [NotchSection]

    /// Fournie par la composition root : déclenche un refresh manuel des jauges (REQ-USG-31).
    public var onRefreshUsage: (@MainActor () -> Void)?
    /// Notifiée à chaque ouverture du panel (scan serveurs immédiat, résolution des routes).
    public var onPanelOpened: (@MainActor () -> Void)?

    private var surfaces: [String: Surface] = [:]
    private var screenSnapshot: [String: CGRect] = [:]
    private var defaultCenterObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?

    /// Le panel reste ouvert tant que la fenêtre Settings est key (REQ-NUI-21) — câblé en M6.
    public var settingsWindowIsKey: Bool = false

    // MARK: - « Act » (prompts inline, hotkeys, focus clavier)

    public let hotkeys = HotkeyManager()
    /// Fournie par la composition root : ouvrir le terminal hôte d'un prompt (⌥T).
    public var onOpenTerminal: (@MainActor (PendingPrompt) -> Void)?
    /// Un champ texte d'une carte a-t-il le focus (suspend les hotkeys, REQ-ACT-29).
    private var textFieldFocused = false

    public init(
        sessions: SessionStore,
        prompts: PromptStore,
        usage: UsageStore,
        settings: SettingsStore,
        sections: @escaping @MainActor () -> [NotchSection]
    ) {
        self.sessions = sessions
        self.prompts = prompts
        self.usage = usage
        self.settings = settings
        self.sections = sections
    }

    // MARK: - Cycle de vie

    public func start() {
        rebuildSurfaces(restoreExpanded: false)

        defaultCenterObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenConfigurationChanged() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenConfigurationChanged() }
        }
        EventMonitors.shared.onLeftMouseDown = { [weak self] location in
            self?.handleMouseDown(at: location)
        }
        hotkeys.onAction = { [weak self] action in
            self?.handleHotkey(action)
        }
        prompts.onChange = { [weak self] hasActionable, becameActionable in
            self?.syncActState(hasActionable: hasActionable, becameActionable: becameActionable)
        }
        DashLog.ui.notice("surface notch démarrée (\(self.surfaces.count) écran(s))")
    }

    public func stop() {
        if let defaultCenterObserver {
            NotificationCenter.default.removeObserver(defaultCenterObserver)
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        defaultCenterObserver = nil
        workspaceObserver = nil
        EventMonitors.shared.onLeftMouseDown = nil
        EventMonitors.shared.uninstall()
        for surface in surfaces.values { fade(out: surface.panel) }
        surfaces.removeAll()
    }

    // MARK: - Ouverture / fermeture (05 · §3.3)

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var openAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.8)
    }

    private var closeAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 1.0)
    }

    public func open(reason: OpenReason) {
        for surface in surfaces.values {
            openSurface(surface.vm, animated: true)
        }
        updateMonitors()
        onPanelOpened?()
    }

    /// Un panel est-il ouvert (cadence de scan adaptative, 10 · REQ-SRV-03) ?
    public var isPanelOpen: Bool {
        surfaces.values.contains { $0.vm.isExpanded }
    }

    public func close(reason: CloseReason) {
        guard !settingsWindowIsKey else { return } // REQ-NUI-21
        for surface in surfaces.values {
            closeSurface(surface.vm, animated: true)
        }
        updateMonitors()
    }

    private func openSurface(_ vm: NotchViewModel, animated: Bool) {
        guard vm.state == .pill || vm.state == .closing else { return }
        guard animated else {
            vm.state = .panel
            return
        }
        withAnimation(openAnimation) {
            vm.state = .opening
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450)) // durée du ressort d'ouverture
            if vm.state == .opening { vm.state = .panel }
            self.updateMonitors()
        }
    }

    private func closeSurface(_ vm: NotchViewModel, animated: Bool) {
        guard vm.state == .panel || vm.state == .opening else { return }
        guard animated else {
            vm.state = .pill
            return
        }
        withAnimation(closeAnimation) {
            vm.state = .closing
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(480))
            if vm.state == .closing { vm.state = .pill }
            self.updateMonitors()
        }
    }

    private func updateMonitors() {
        let anyOpen = surfaces.values.contains {
            $0.vm.state == .panel || $0.vm.state == .opening
        }
        if anyOpen {
            EventMonitors.shared.install()
        } else {
            EventMonitors.shared.uninstall()
        }
    }

    // MARK: - « Act » : synchronisation prompts ↔ surface

    /// Appelé après toute mutation du PromptStore. Auto-expand + focus clavier + hotkeys
    /// (08 · REQ-ACT-04, 05 · REQ-NUI-20/55).
    private func syncActState(hasActionable: Bool, becameActionable: Bool) {
        guard hasActionable, let prompt = prompts.focusedPrompt else {
            for surface in surfaces.values { surface.panel.resignKeyIfNeeded() }
            hotkeys.unregister()
            return
        }
        let handling = settings.promptHandling
        if becameActionable, settings.autoExpandOnAttention, handling != .terminalOnly {
            open(reason: .attention)
        }
        // Annonce VoiceOver à l'apparition d'un prompt (REQ-NUI-57).
        if becameActionable {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: AccessibilityLabels.promptAnnouncement(prompt),
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        // Le panel devient key pour router les frappes (sans activer l'app, REQ-NUI-55).
        for surface in surfaces.values where surface.vm.isExpanded {
            surface.panel.makeKeyIfNeeded()
        }
        // Diagnostic honnête : le panel est-il RÉELLEMENT key (⌘A fonctionnera-t-il) ?
        let anyKey = surfaces.values.contains { $0.panel.isKeyWindow }
        DashLog.file("act: prompt affiché — panneau key=\(anyKey), app active=\(NSApp.isActive), hotkeys=\(hotkeys.registrationFailures.isEmpty ? "ok" : "échec")", category: "ui")
        refreshHotkeys(for: prompt)
    }

    private func refreshHotkeys(for prompt: PendingPrompt) {
        guard !textFieldFocused else { hotkeys.suspend(); return }
        let isPlan: Bool = if case .plan = prompt.payload { true } else { false }
        let isQuestion: Bool = if case .question = prompt.payload { true } else { false }
        hotkeys.register(for: prompt.capabilities, isPlan: isPlan, isQuestion: isQuestion)
    }

    public func setTextFieldFocused(_ focused: Bool) {
        textFieldFocused = focused
        if let prompt = prompts.focusedPrompt { refreshHotkeys(for: prompt) }
    }

    private func handleHotkey(_ action: HotkeyManager.Action) {
        // SÉCURITÉ (08 · risque 4) : `RegisterEventHotKey` est GLOBAL. Sans garde, un ⌘A tapé
        // dans l'éditeur (select-all) déclencherait Allow. On n'agit que si le panneau notch
        // est la key window : dès que l'utilisateur bascule dans une autre app, notre app
        // resigne et le panneau perd le statut key → ⌘A retrouve son sens natif ailleurs.
        let notchEngaged = surfaces.values.contains { $0.panel.isKeyWindow }
        if action != .openTerminal, !notchEngaged { return } // ⌥T (ouvrir le terminal) reste permis
        guard let prompt = prompts.focusedPrompt else { return }
        switch action {
        case .allow:
            let decision: PromptDecision = if case .plan = prompt.payload {
                .approvePlan(switchToAcceptEdits: false)
            } else { .allow }
            prompts.decide(prompt.id, decision, via: .hotkey)
        case .deny:
            let decision: PromptDecision = if case .plan = prompt.payload {
                .rejectPlan(feedback: "")
            } else { .deny(feedback: nil) }
            prompts.decide(prompt.id, decision, via: .hotkey)
        case .alwaysAllow:
            if case .permission(let request) = prompt.payload, let suggestion = request.suggestions.first {
                prompts.decide(prompt.id, .alwaysAllow(suggestion), via: .hotkey)
            }
        case .openTerminal:
            onOpenTerminal?(prompt)
        }
    }

    // MARK: - Clic extérieur (05 · §3.5)

    private func handleMouseDown(at location: NSPoint) {
        guard !settingsWindowIsKey else { return }
        for surface in surfaces.values
        where surface.vm.state == .panel || surface.vm.state == .opening {
            if !panelScreenRect(of: surface).contains(location) {
                closeSurface(surface.vm, animated: true)
            }
        }
        updateMonitors()
    }

    private func panelScreenRect(of surface: Surface) -> NSRect {
        let frame = surface.panel.frame
        var size = surface.vm.panelRenderedSize
        if size == .zero {
            size = CGSize(width: settings.panelWidth.points, height: 420)
        }
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Écrans (05 · §3.6)

    private func screenConfigurationChanged() {
        let snapshot = currentScreenSnapshot()
        guard snapshot != screenSnapshot else { return }
        DashLog.ui.notice("reconfiguration d'écrans détectée")
        rebuildSurfaces(restoreExpanded: true)
    }

    private func currentScreenSnapshot() -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for screen in NSScreen.screens {
            if let uuid = screen.displayUUID { result[uuid] = screen.frame }
        }
        return result
    }

    private func rebuildSurfaces(restoreExpanded: Bool) {
        let wasExpanded = surfaces.values.contains { $0.vm.isExpanded }
        for surface in surfaces.values { surface.panel.orderOut(nil) }
        surfaces.removeAll()
        screenSnapshot = currentScreenSnapshot()

        guard settings.notchEnabled,
              let screen = resolveTargetScreen(),
              let geometry = NotchGeometry(screen: screen) else { return }

        // Fenêtre créée une seule fois à sa taille maximale, jamais redimensionnée (REQ-NUI-05).
        let width = PanelWidth.ultraWide.points + 2 * NotchGeometry.shadowPadding
        let height = max(300, screen.visibleFrame.height - 20)
        let rect = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height, // bord supérieur = frame.maxY (REQ-NUI-07)
            width: width,
            height: height
        )

        let panel = NotchPanel(contentRect: rect)
        if settings.hideFromScreenRecording { panel.sharingType = .none } // REQ-NUI-09
        let vm = NotchViewModel(geometry: geometry)
        let root = NotchRootView(
            vm: vm,
            coordinator: self,
            sessions: sessions,
            prompts: prompts,
            usage: usage,
            settings: settings,
            onRefreshUsage: { [weak self] in self?.onRefreshUsage?() },
            sections: sections
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        surfaces[geometry.screenUUID] = Surface(panel: panel, vm: vm)

        // Premier affichage : fondu 0 → 1 en 0,15 s (REQ-NUI-48).
        panel.alphaValue = 0
        panel.orderFrontRegardless() // jamais makeKeyAndOrderFront (REQ-NUI-06)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        if restoreExpanded && wasExpanded {
            openSurface(vm, animated: false) // restauration sans animation (05 · §3.6)
        }
        updateMonitors()
    }

    private func resolveTargetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        switch settings.preferredScreen {
        case .builtinThenMain:
            return screens.first(where: \.isBuiltinDisplay) ?? NSScreen.main ?? screens.first
        case .active:
            return NSScreen.main ?? screens.first
        case .uuid(let uuid):
            return screens.first(where: { $0.displayUUID == uuid })
                ?? screens.first(where: \.isBuiltinDisplay)
                ?? NSScreen.main
                ?? screens.first
        }
    }

    private func fade(out panel: NotchPanel) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }
}
