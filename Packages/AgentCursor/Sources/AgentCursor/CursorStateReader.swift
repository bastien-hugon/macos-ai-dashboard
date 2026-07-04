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

    /// Signature stable par session pour éviter de republier (et re-render) à chaque poll,
    /// et pour ne recharger la timeline (lecture de bulles) que des sessions qui changent.
    private var lastSignatures: [String: String] = [:]
    /// Timelines déjà chargées (réutilisées si la session n'a pas changé).
    private var cachedDetails: [String: CursorTimelineReader.Detail] = [:]

    public func start() {
        pollOnce()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Poll adaptatif : 3 s si une session Cursor demande une action, sinon 12 s
                // (la DB fait ~1 Go — inutile de la relire souvent au repos).
                let interval = await self?.pollInterval() ?? 12
                try? await Task.sleep(for: .seconds(interval))
                await self?.pollOnce()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollInterval() -> Double {
        lastPublished.contains { $0.state == .waiting || $0.state == .executing } ? 3 : 12
    }

    public func pollOnce() {
        guard let reader = SQLiteReader(path: paths.cursorGlobalStorageDB.path),
              let data = reader.itemValue(key: "composer.composerHeaders") else { return }
        var sessions = Self.parseComposers(data)

        // Enrichit (timeline + subagents) UNIQUEMENT les sessions dont la signature a changé ;
        // les autres réutilisent la timeline en cache. Borne les lectures de bulles.
        var changed = false
        for i in sessions.indices {
            let id = sessions[i].id.nativeID
            let sig = "\(sessions[i].state.rawValue)|\(sessions[i].title)|\(sessions[i].diff.added),\(sessions[i].diff.removed)|\(sessions[i].filesTouched)|\(sessions[i].lastActivity ?? "")|\(Int(sessions[i].contextPercent ?? -1))"
            if lastSignatures[id] != sig {
                lastSignatures[id] = sig
                changed = true
                if let detail = CursorTimelineReader.read(reader: reader, composerId: id) {
                    cachedDetails[id] = detail
                }
            }
            if let detail = cachedDetails[id] {
                sessions[i].timeline = detail.timeline
                sessions[i].subagentCount = detail.subagentCount
                if let activity = detail.lastActivity { sessions[i].lastActivity = activity }
            }
        }
        // GC du cache des sessions disparues.
        let present = Set(sessions.map(\.id.nativeID))
        lastSignatures = lastSignatures.filter { present.contains($0.key) }
        cachedDetails = cachedDetails.filter { present.contains($0.key) }

        guard changed || sessions.count != lastPublished.count else { return }
        lastPublished = sessions
        if let handler = snapshotHandler {
            let snapshot = sessions
            Task { @MainActor in handler(snapshot) }
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
            // % de contexte (gratuit depuis composerHeaders) — chip « ctx X% » (REQ-SES-23).
            session.contextPercent = (composer["contextUsagePercent"] as? NSNumber)?.doubleValue
            sessions.append(session)
        }
        return sessions
    }

    /// « récent » = mis à jour il y a moins de 20 s (heuristique d'activité).
    private static func recent(_ epochMs: NSNumber) -> Bool {
        Date().timeIntervalSince1970 - epochMs.doubleValue / 1000 < 20
    }
}
