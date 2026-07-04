import AgentClaude
import AgentCursor
import AppKit
import DashCore
import NotchUI
import SwiftUI

/// Point d'entrée. App d'arrière-plan (`LSUIElement` dans l'Info.plist du bundle ;
/// `.accessory` est aussi forcé par code pour que `swift run` se comporte pareil).
@main
@MainActor
enum AppMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var sessions: SessionStore!
    private var prompts: PromptStore!
    private var coordinator: NotchSurfaceCoordinator!
    private var claudeProvider: ClaudeSessionProvider?
    private var cursorReader: CursorStateReader?
    private var hookServer: HookServer?
    private var usage: UsageStore!
    private var usageController: ClaudeUsageController?
    private var cursorUsageController: CursorUsageController?
    private var servers: ServerStore!
    private var fastActions: FastActionStore!
    private var serversController: ServersController!
    private var menuBar: MenuBarController?
    private var notifications: NotificationsController!
    private var doctor: DoctorStore!
    private var doctorController: DoctorController!
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: NSWindow?
    private let perfMonitor = PerfMonitor()
    private let paths = DashPaths.live()
    private var releaseTimer: Timer?
    private var countdownTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = SystemClock().monotonicSeconds

        settings = SettingsStore()
        sessions = SessionStore()
        prompts = PromptStore()
        usage = UsageStore()

        // Résilience (M16) : affiche le dernier snapshot de sessions instantanément, avant
        // que les sources ne republient (< 1 s). Marqué non-live tant que non reconfirmé.
        let stateCache = StateCache(paths: paths)
        if let cached = stateCache.loadSessions() {
            sessions.replaceAll(cached)
        }
        servers = ServerStore()
        fastActions = FastActionStore()
        serversController = ServersController(store: servers, paths: paths)
        let sessions = sessions!
        let settings = settings!
        let prompts = prompts!
        let usage = usage!
        let servers = servers!
        let fastActions = fastActions!
        let serversController = serversController!

        // Réglages d'usage injectés dans le store (dérivation des jauges).
        usage.settingsProvider = {
            UsageStore.UsageSettings(
                countdownFrom100: settings.countdownFrom100,
                clock24h: settings.clock24h,
                threshold5h: settings.budgetThreshold5h,
                threshold7d: settings.budgetThreshold7d
            )
        }

        // Notifications système (M5) : autorisation, catégories, post/retrait.
        notifications = NotificationsController(settings: settings, prompts: prompts)
        let notifications = notifications!

        // Doctor (M6).
        doctor = DoctorStore()
        doctorController = DoctorController(store: doctor, settings: settings, paths: paths)
        let doctor = doctor!
        let doctorController = doctorController!

        // Fenêtre Settings (M6).
        let settingsWindow = SettingsWindowController {
            AnyView(SettingsView(
                settings: settings, doctor: doctor, usage: usage, fastActions: fastActions,
                onRunDoctor: { doctorController.run() },
                onDoctorRemedy: { doctorController.applyRemedy($0) },
                onSendTestNotification: { notifications.sendTest() },
                onRetryKeychain: { [weak self] in Task { await self?.usageController?.start() } },
                onQuit: { NSApp.terminate(nil) }
            ))
        }
        settingsWindow.onKeyChange = { [weak self] isKey in
            self?.coordinator?.settingsWindowIsKey = isKey
        }
        self.settingsWindow = settingsWindow

        // Transition d'état optimiste + retrait de la notification à chaque décision.
        prompts.onDecision = { sessionID, decision, _ in
            sessions.applyOptimisticDecision(sessionID, decision)
            notifications.onPromptResolved(session: sessionID)
        }
        // Prompt arrivé → notification (permission demandée, REQ-NOT-08). Hook dédié :
        // le coordinateur possède onChange (auto-expand/hotkeys), on ne le clobbe pas.
        prompts.onPromptArrived = { prompt in
            let title: String = switch prompt.payload {
            case .permission(let r): r.displayTitle
            case .plan(let p): p.title
            case .question: "Answer a question"
            }
            notifications.onPromptArrived(session: prompt.sessionID,
                                          projectName: prompt.sessionLabel, toolTitle: title)
        }
        // Alerte de budget → notification.
        usage.onBudgetAlert = { alert in
            let resetsAt = usage.windows[alert.kind]?.resetsAt
            notifications.onBudgetAlert(alert, resetsAt: resetsAt)
        }

        // Composition root : les sections du panel sont injectées ici (01 · §3.2).
        coordinator = NotchSurfaceCoordinator(
            sessions: sessions,
            prompts: prompts,
            usage: usage,
            settings: settings,
            sections: {
                Self.buildSections(sessions: sessions, usage: usage, settings: settings,
                                   servers: servers, fastActions: fastActions,
                                   serversController: serversController)
            }
        )
        serversController.isPanelOpen = { [weak coordinator] in coordinator?.isPanelOpen ?? false }
        coordinator.onPanelOpened = {
            serversController.scanNow()
            serversController.resolveRoutes()
        }
        coordinator.onOpenTerminal = { prompt in
            let cwd: String = if case .permission(let req) = prompt.payload { req.cwd } else { "" }
            TerminalOpener.open(termProgram: prompt.termProgram, cwd: cwd)
        }
        coordinator.onRefreshUsage = { [weak self] in
            usage.beginManualRefresh()
            Task { await self?.usageController?.refreshNow() }
        }

        // Le canal IPC doit être prêt AVANT tout le reste (01 · §4.3) : des hooks peuvent
        // arriver immédiatement.
        startHookServer()

        // Installation/réparation des hooks (idempotent) si le toggle est actif.
        if settings.claudeHooksEnabled {
            copyHookBinary()
            Task {
                try? await ClaudeHooksInstaller(paths: paths).installOrRepair()
                // Cursor : créer/fusionner ~/.cursor/hooks.json (si Cursor détecté).
                if FileManager.default.fileExists(atPath: paths.cursorDir.path) {
                    try? await CursorHooksInstaller(paths: paths).installOrRepair()
                }
            }
        }

        if settings.notchEnabled {
            coordinator.start()
        }
        serversController.start()

        // Barre de menus (M5).
        if settings.menuBarEnabled {
            let menuBar = MenuBarController(
                sessions: sessions, usage: usage, servers: servers, settings: settings,
                onRefreshUsage: { [weak self] in usage.beginManualRefresh(); Task { await self?.usageController?.refreshNow() } },
                onStopServer: { serversController.requestStop($0) },
                onOpenSettings: { settingsWindow.show() }
            )
            menuBar.install()
            self.menuBar = menuBar
        }

        // Autorisation notifications : au lancement seulement si l'onboarding est déjà passé
        // (sinon l'étape Notifications de l'onboarding s'en charge, REQ-LIC-05).
        if settings.notificationsMasterEnabled, settings.onboardingCompleted {
            notifications.requestAuthorization()
        }

        // Ingestion Claude Code (M1, mode fallback : transcripts + registre PID).
        let provider = ClaudeSessionProvider(paths: .live())
        claudeProvider = provider
        Task {
            await provider.setSnapshotHandler { snapshot in
                sessions.applySnapshot(snapshot, agent: .claude)
            }
            await provider.start()
        }

        // Ingestion Cursor (M7 : lecture state.vscdb, poll 4 s).
        if FileManager.default.fileExists(atPath: paths.cursorGlobalStorageDB.path) {
            let cursorReader = CursorStateReader(paths: paths)
            self.cursorReader = cursorReader
            Task {
                await cursorReader.setSnapshotHandler { snapshot in
                    sessions.applySnapshot(snapshot, agent: .cursor)
                }
                await cursorReader.start()
            }
        }

        // Auto-libération des prompts expirés (08 · REQ-ACT-07) + rollover d'usage + détection
        // « stuck » (12 · REQ-NOT-10) — tick 1 s.
        var lastSnapshotSave = Date.distantPast
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                prompts.releaseExpired(now: Date())
                usage.rolloverIfNeeded(now: Date())
                self?.checkStuckSessions(sessions: sessions, notifications: notifications)
                // Snapshot des sessions toutes les 10 s (résilience, M16).
                if Date().timeIntervalSince(lastSnapshotSave) >= 10 {
                    lastSnapshotSave = Date()
                    stateCache.saveSessions(sessions.sessions)
                }
            }
        }

        // Usage Claude (M3) : poller endpoint OAuth + stats journalières, si le toggle est actif.
        if settings.claudeUsageEnabled {
            let controller = ClaudeUsageController(paths: paths, store: usage)
            usageController = controller
            Task { await controller.start() }
        }

        // Usage Cursor mensuel (M7) : session locale → endpoint dashboard, si Cursor présent.
        if settings.cursorUsageEnabled, FileManager.default.fileExists(atPath: paths.cursorGlobalStorageDB.path) {
            let controller = CursorUsageController(paths: paths, store: usage) {
                CursorUsageMeasure(rawValue: settings.cursorMeasure) ?? .weighted
            }
            cursorUsageController = controller
            Task { await controller.start() }
        }

        // Poll immédiat + rollover au réveil (REQ-USG-23).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                usage.rolloverIfNeeded(now: Date())
                Task { await self?.usageController?.refreshNow() }
            }
        }

        Task { await perfMonitor.start() }

        let elapsedMs = (SystemClock().monotonicSeconds - launchStart) * 1000
        DashLog.ui.notice("AgentDash démarré en \(elapsedMs, format: .fixed(precision: 0)) ms")
        DashLog.file("démarrage AgentDash", category: "app")

        // Aide au test : AGENTDASH_OPEN_SETTINGS=1 ouvre Settings au lancement (dev/QA).
        if ProcessInfo.processInfo.environment["AGENTDASH_OPEN_SETTINGS"] == "1" {
            settingsWindow.show()
        }

        // Onboarding au premier lancement (14 · REQ-LIC-01) ou forcé via env (QA).
        if !settings.onboardingCompleted || ProcessInfo.processInfo.environment["AGENTDASH_ONBOARDING"] == "1" {
            showOnboarding()
        }

        // QA : force l'ouverture du panel notch pour inspection/capture.
        if ProcessInfo.processInfo.environment["AGENTDASH_FORCE_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.coordinator?.open(reason: .click)
            }
        }
        // QA : ouvre le popover de la barre de menus sans clic.
        if ProcessInfo.processInfo.environment["AGENTDASH_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.menuBar?.showPopoverForTesting()
            }
        }
    }

    private func showOnboarding() {
        let paths = paths
        let settings = settings!
        let notifications = notifications!
        let view = OnboardingView(
            settings: settings,
            claudeStatus: { await ClaudeHooksInstaller(paths: paths).status() },
            cursorStatus: {
                FileManager.default.fileExists(atPath: paths.cursorDir.path)
                    ? await CursorHooksInstaller(paths: paths).status() : .agentNotDetected
            },
            installClaude: {
                self.copyHookBinary()
                try? await ClaudeHooksInstaller(paths: paths).installOrRepair()
            },
            installCursor: { try? await CursorHooksInstaller(paths: paths).installOrRepair() },
            requestNotifications: { notifications.requestAuthorization() },
            onFinish: { [weak self] in
                settings.onboardingCompleted = true
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "AgentDash"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseTimer?.invalidate()
        countdownTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        hookServer?.stop()
        coordinator?.stop()
    }

    // MARK: - IPC (M2)

    private func startHookServer() {
        let prompts = prompts!
        let sessions = sessions!
        let settings = settings!
        let server = HookServer(socketPath: paths.socketPath) { [weak self] request in
            // Self-test du Doctor (REQ-SET-55) : prouve l'aller-retour IPC de bout en bout.
            if request.envelope.eventJSON.contains("__agentdash_selftest") {
                request.reply(Data(#"{"selftest":"ok"}"#.utf8))
                return
            }
            // Queue réseau → rebond sur MainActor pour muter les stores.
            // Branchement par agent d'origine (Claude Code vs Cursor).
            let isCursor = request.envelope.source == "cursor"
            let decision: PendingPrompt?
            var stopTelemetry: SessionID?
            var toolResolvedTelemetry: SessionID?
            if isCursor {
                switch CursorEventRouter.route(request.envelope, now: Date()) {
                case .decision(let p): decision = p
                case .telemetry(let s, let isStop): decision = nil; if isStop { stopTelemetry = s }
                case .ignore: decision = nil
                }
            } else {
                switch ClaudeEventRouter.route(request.envelope, now: Date()) {
                case .decision(let p): decision = p
                case .telemetry(let t):
                    decision = nil
                    switch t.kind {
                    case .stop: stopTelemetry = t.sessionID
                    case .toolResolved: toolResolvedTelemetry = t.sessionID
                    case .sessionEnd, .notification: break
                    }
                case .ignore: decision = nil
                }
            }
            Task { @MainActor in
                if let prompt = decision {
                    if settings.promptHandling == .terminalOnly {
                        request.reply(nil)
                        return
                    }
                    sessions.markWaiting(prompt.sessionID)
                    request.onRemoteClose = { [weak prompts] in
                        Task { @MainActor in prompts?.retire(prompt.id, outcome: .released) }
                    }
                    prompts.enqueue(prompt) { data in request.reply(data) }
                    return
                }
                if let sid = stopTelemetry {
                    self?.applyTelemetry(.init(sessionID: sid, kind: .stop), sessions: sessions, prompts: prompts)
                } else if let sid = toolResolvedTelemetry {
                    self?.applyTelemetry(.init(sessionID: sid, kind: .toolResolved(toolUseID: nil)), sessions: sessions, prompts: prompts)
                }
                request.reply(nil)
            }
        }
        do {
            try server.start()
            hookServer = server
        } catch {
            DashLog.ipc.error("démarrage HookServer impossible : \(error.localizedDescription)")
        }
    }

    /// Détection « stuck » (12 · REQ-NOT-10) : une session en `executing`/`thinking` sans
    /// événement depuis 120 s. Une seule notification par session par épisode.
    private var stuckNotified: Set<SessionID> = []
    @MainActor
    private func checkStuckSessions(sessions: SessionStore, notifications: NotificationsController) {
        let now = Date()
        for session in sessions.displaySessions {
            let active = session.state == .executing || session.state == .thinking
            let stale = now.timeIntervalSince(session.lastEventAt) > 120
            let key = session.id
            if active, stale {
                if !stuckNotified.contains(key) {
                    stuckNotified.insert(key)
                    notifications.onStuckSession(session: key, projectName: session.projectName,
                                                 seconds: Int(now.timeIntervalSince(session.lastEventAt)))
                }
            } else {
                stuckNotified.remove(key) // réactivité → réarme
            }
        }
    }

    @MainActor
    private func applyTelemetry(_ telemetry: ClaudeEventRouter.ClaudeTelemetry,
                                sessions: SessionStore, prompts: PromptStore) {
        switch telemetry.kind {
        case .toolResolved:
            if let stale = prompts.prompts.first(where: { $0.sessionID == telemetry.sessionID }) {
                prompts.retire(stale.id, outcome: .released)
            }
        case .stop:
            // Fin de tour → notification « tâche terminée » (REQ-NOT-11).
            if let stale = prompts.prompts.first(where: { $0.sessionID == telemetry.sessionID }) {
                prompts.retire(stale.id, outcome: .released)
            }
            let project = sessions.sessions.first { $0.id == telemetry.sessionID }?.projectName ?? "Claude Code"
            notifications?.onTaskComplete(session: telemetry.sessionID, projectName: project)
        case .sessionEnd, .notification:
            break // cycle de vie détaillé traité par le provider (M1)
        }
    }

    /// Copie le binaire hook du bundle vers ~/.agentdash/bin (resynchronisation = « réparer »).
    private func copyHookBinary() {
        // Cherche dans Contents/Helpers (bundle), sinon à côté de l'exécutable (`swift run`).
        let helperInBundle = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/agentdash-hook")
        let bundled: URL? = FileManager.default.isExecutableFile(atPath: helperInBundle.path)
            ? helperInBundle
            : helperURLFallback()
        guard let bundled else {
            DashLog.claude.error("binaire agentdash-hook introuvable dans le bundle")
            return
        }
        let dest = paths.hookBinary
        try? FileManager.default.createDirectory(at: paths.hookBinaryDir, withIntermediateDirectories: true)
        // Resynchronise si absent ou différent (comparaison de contenu).
        let bundledData = try? Data(contentsOf: bundled)
        let destData = try? Data(contentsOf: dest)
        if bundledData != destData {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: bundled, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            DashLog.claude.notice("binaire agentdash-hook resynchronisé")
        }
    }

    private func helperURLFallback() -> URL? {
        // Exécution via `swift run` (hors bundle) : le binaire est à côté de l'exécutable.
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidate = exeDir.appending(path: "agentdash-hook")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Sections du panel — ordre (05 · REQ-NUI-33) : sessions, usage, serveurs, routes, actions.
    static func buildSections(
        sessions: SessionStore, usage: UsageStore, settings: SettingsStore,
        servers: ServerStore, fastActions: FastActionStore, serversController: ServersController
    ) -> [NotchSection] {
        [
            NotchSection(id: "sessions", title: "Sessions", isEmpty: sessions.displaySessions.isEmpty) {
                if sessions.displaySessions.isEmpty {
                    // REQ-SES-43 : état vide.
                    EmptySectionView(
                        icon: "rectangle.stack",
                        title: "No sessions yet",
                        subtitle: "Sessions appear when Claude Code or Cursor is active."
                    )
                } else {
                    SessionListView(
                        store: sessions, settings: settings,
                        onKill: { SessionActions.kill($0, store: sessions) },
                        onCopyMarkdown: { SessionActions.copyMarkdown($0) },
                        onDismiss: { sessions.dismiss($0.id) },
                        onOpenTerminal: { SessionActions.openTerminal($0) }
                    )
                }
            },
            // La section Usage a été remplacée par la ligne inline centrée en haut du panel
            // (UsageInlineView dans le header) ; les jauges détaillées restent dans le
            // popover de la barre de menus.
            // Section repliable (gain de place) : repliée par défaut, badge = nb de serveurs.
            NotchSection(id: "servers", title: nil, isEmpty: false) {
                NotchDisclosureSection(
                    title: "Local servers",
                    badge: "\(servers.count)",
                    isExpanded: Binding(
                        get: { settings.serversSectionExpanded },
                        set: { settings.serversSectionExpanded = $0 }
                    ),
                    settings: settings
                ) {
                    ServersSectionView(store: servers, settings: settings) { server in
                        serversController.requestStop(server)
                    }
                }
            },
            NotchSection(
                id: "routes", title: "Quick Routes",
                isEmpty: serversController.routes.allSatisfy(\.existing.isEmpty),
                hidesWhenEmpty: true // REQ-QRF-07
            ) {
                QuickRoutesSectionView(routes: serversController.routes) { route, path in
                    serversController.openRoute(route, path: path)
                }
            },
            NotchSection(id: "fastactions", title: "Fast Actions", isEmpty: fastActions.actions.isEmpty, hidesWhenEmpty: true) {
                FastActionsSectionView(store: fastActions) { action in
                    serversController.run(action, store: fastActions)
                }
            },
        ]
    }
}

/// État vide d'une section (05 · REQ-NUI-36) — style à calibrer en M6.
struct EmptySectionView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
    }
}
