import DashCore
import Foundation

/// Lit les sessions Cursor depuis `state.vscdb` (04 · §2, research cursor §2.3) :
/// registre `composer.composerHeaders.allComposers[]` de `ItemTable`. Filtre les brouillons,
/// archivés et subagents (jamais de row racine). Poll adaptatif possédé par l'app.
public actor CursorStateReader {
    private let paths: DashPaths
    private var snapshotHandler: (@MainActor @Sendable ([Session]) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var lastPublished: [Session] = []

    public init(paths: DashPaths) {
        self.paths = paths
    }

    public func setSnapshotHandler(_ handler: @escaping @MainActor @Sendable ([Session]) -> Void) {
        snapshotHandler = handler
    }

    public func start() {
        pollOnce()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await self?.pollOnce()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func pollOnce() {
        guard let reader = SQLiteReader(path: paths.cursorGlobalStorageDB.path),
              let data = reader.itemValue(key: "composer.composerHeaders") else { return }
        let sessions = Self.parseComposers(data)
        guard sessions != lastPublished else { return }
        lastPublished = sessions
        if let handler = snapshotHandler {
            Task { @MainActor in handler(sessions) }
        }
    }

    // MARK: - Parsing (pur, testable)

    static func parseComposers(_ data: Data) -> [Session] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = root["allComposers"] as? [[String: Any]] else { return [] }
        var sessions: [Session] = []
        for composer in all {
            guard let id = composer["composerId"] as? String else { continue }
            // Filtres (04 · REQ-SES-10) : brouillons, archivés, subagents, best-of-N exclus.
            if composer["isDraft"] as? Bool == true { continue }
            if composer["isArchived"] as? Bool == true { continue }
            if composer["isBestOfNSubcomposer"] as? Bool == true { continue }
            if composer["subagentInfo"] != nil { continue }

            let hasBlocking = composer["hasBlockingPendingActions"] as? Bool == true
            let hasPlan = composer["hasPendingPlan"] as? Bool == true
            let state: SessionState = hasBlocking || hasPlan ? .waiting
                : ((composer["conversationCheckpointLastUpdatedAt"] as? NSNumber).map { recent($0) } ?? false ? .executing : .idle)

            let created = (composer["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
            let updated = (composer["lastUpdatedAt"] as? NSNumber)
                ?? (composer["conversationCheckpointLastUpdatedAt"] as? NSNumber)
            let lastEvent = updated.map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? created

            let workspace = composer["workspaceIdentifier"] as? [String: Any]
            let projectPath = (workspace?["uri"] as? [String: Any])?["fsPath"] as? String

            var session = Session(
                id: SessionID(agent: .cursor, nativeID: id),
                state: state,
                liveness: .live,
                title: composer["name"] as? String ?? "",
                projectPath: projectPath,
                startedAt: created,
                lastEventAt: lastEvent,
                host: .ide("Cursor"),
                diff: DiffStats(
                    added: composer["totalLinesAdded"] as? Int ?? 0,
                    removed: composer["totalLinesRemoved"] as? Int ?? 0
                ),
                filesTouched: composer["filesChangedCount"] as? Int ?? 0
            )
            session.lastActivity = composer["subtitle"] as? String
            sessions.append(session)
        }
        return sessions
    }

    /// « récent » = mis à jour il y a moins de 20 s (heuristique d'activité).
    private static func recent(_ epochMs: NSNumber) -> Bool {
        Date().timeIntervalSince1970 - epochMs.doubleValue / 1000 < 20
    }
}
