import AppKit
import DashCore
import Foundation
import ServersKit

import Observation

/// Orchestre le scan des serveurs (cadence adaptative 2 s panel ouvert / 10 s sinon,
/// 10 · REQ-SRV-03), l'arrêt en deux temps, les Quick Routes et les Fast Actions.
@MainActor @Observable
final class ServersController {
    private let store: ServerStore
    private let paths: DashPaths
    private var loopTask: Task<Void, Never>?
    /// Fournie par la composition root : le panel est-il ouvert ?
    var isPanelOpen: (@MainActor () -> Bool)?

    private(set) var routes: [QuickRoute] = []

    init(store: ServerStore, paths: DashPaths) {
        self.store = store
        self.paths = paths
        routes = QuickRoute.catalog(home: paths.home.path)
    }

    func start() {
        scanNow()
        resolveRoutes()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                let open = await MainActor.run { self?.isPanelOpen?() ?? false }
                try? await Task.sleep(for: .seconds(open ? 2 : 10))
                await self?.scanNowAsync()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func scanNow() {
        Task { await scanNowAsync() }
    }

    private func scanNowAsync() async {
        // Scan + identification hors MainActor (01 · §5.2).
        let servers = await Task.detached(priority: .utility) { ServerBuilder.build() }.value
        store.applyScan(servers)
    }

    // MARK: - Arrêt en deux temps (REQ-SRV-31)

    func requestStop(_ server: DevServer) {
        switch server.stopState {
        case .none, .gone:
            store.setStopState(server.id, .confirming(until: Date().addingTimeInterval(3)))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                // Expiration de la confirmation.
                if case .confirming = self?.storeState(server.id) {
                    self?.store.setStopState(server.id, .none)
                }
            }
        case .confirming:
            store.setStopState(server.id, .terminating)
            Task { [weak self] in
                let outcome = await ServerStopper.stop(
                    pid: server.id.pid,
                    startTimeSec: server.startTimeSec,
                    execPath: server.execPath
                )
                await MainActor.run {
                    switch outcome {
                    case .terminated, .alreadyGone:
                        self?.store.setStopState(server.id, .gone)
                    case .stillAlive, .refused:
                        self?.store.setStopState(server.id, .none)
                        DashLog.servers.error("arrêt impossible :\(server.id.port) (\(String(describing: outcome)))")
                    }
                    self?.scanNow()
                }
            }
        case .terminating:
            break
        }
    }

    private func storeState(_ id: DevServer.ID) -> StopState? {
        store.servers.first { $0.id == id }?.stopState
    }

    // MARK: - Quick Routes (11 · REQ-QRF-03)

    func resolveRoutes() {
        let catalog = QuickRoute.catalog(home: paths.home.path)
        Task.detached(priority: .utility) {
            let resolved = catalog.map { route in
                var route = route
                route.existing = route.candidates.filter { FileManager.default.fileExists(atPath: $0) }
                return route
            }
            await MainActor.run { [weak self] in self?.routes = resolved }
        }
    }

    func openRoute(_ route: QuickRoute, path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            resolveRoutes() // disparu entre résolution et clic (REQ-QRF-08)
            return
        }
        if route.revealsFile {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    // MARK: - Fast Actions

    func run(_ action: FastAction, store: FastActionStore) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", action.command]
            if let wd = action.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: wd)
            }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let code = process.terminationStatus
                await MainActor.run { store.recordRun(action.id, exitCode: code) }
            } catch {
                await MainActor.run { store.recordRun(action.id, exitCode: -1) }
            }
        }
    }
}
