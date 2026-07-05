import Foundation
import Observation

/// Groupe de sessions par projet (07 · REQ-SES-02).
public struct SessionGroup: Identifiable, Sendable {
    public let id: String       // projectPath normalisé, ou "~other" pour le groupe terminal
    public let name: String
    public let sessions: [Session]
}

/// Store des sessions — source de vérité UI (01 · §5.1), mutations sur MainActor.
/// M1 : alimenté par les snapshots du provider Claude (source transcript/fallback) ;
/// la fusion fine multi-sources avec fenêtre d'autorité des hooks arrive au jalon M2.
@MainActor @Observable
public final class SessionStore {
    public private(set) var sessions: [Session] = []

    public init() {}

    // MARK: - Ingestion

    /// Remplace l'ensemble des sessions d'un agent (snapshot d'une source unique).
    /// La déduplication est structurelle : clé `SessionID` (07 · REQ-SES-08).
    public func applySnapshot(_ snapshot: [Session], agent: AgentKind) {
        var byID: [SessionID: Session] = [:]
        for session in snapshot where session.id.agent == agent {
            byID[session.id] = session
        }
        sessions = sessions.filter { $0.id.agent != agent } + byID.values
    }

    public func replaceAll(_ new: [Session]) {
        sessions = new
    }

    // MARK: - Agrégats (pill)

    /// État agrégé pour l'indicateur du pill (priorité waiting > executing > thinking > idle).
    public var aggregateState: SessionState {
        displaySessions.map(\.state)
            .max(by: { $0.attentionPriority < $1.attentionPriority }) ?? .idle
    }

    /// Nombre de sessions live non idle (aile droite du pill, 05 · REQ-NUI-25).
    public var liveCount: Int {
        displaySessions.filter { $0.liveness.isLive && $0.state != .idle }.count
    }

    // MARK: - Affichage (07 · REQ-SES-02/03/04)

    /// Sessions visibles : ni dismissées, ni terminées depuis plus de 24 h (GC d'affichage,
    /// 03 · REQ-CLA-76 — `sessionRetentionHours`).
    public var displaySessions: [Session] {
        let cutoff = Date(timeIntervalSinceNow: -24 * 3600)
        return sessions.filter { session in
            guard !session.isDismissed else { return false }
            // Cursor marque tous ses composers `.live` à vie (pas de notion de fin fiable
            // dans `state.vscdb`) : sans ce garde, tout l'historique de conversations idle
            // encombrerait le panel. On n'affiche donc que les sessions Cursor actives
            // (waiting/executing) — les convos au repos restent lisibles côté Cursor.
            if session.id.agent == .cursor {
                return session.state != .idle
            }
            if session.liveness.isLive { return true }
            return session.lastEventAt > cutoff
        }
    }

    // Anti-sautillement (07 · REQ-SES-05) : un réordonnancement dû UNIQUEMENT à `lastEventAt`
    // est appliqué au plus une fois toutes les 2 s ; un changement de rang d'état ou
    // l'apparition/disparition d'une session réordonne immédiatement.
    private var cachedOrder: [SessionID] = []
    private var lastStructuralSignature = ""
    private var lastReorderAt: Date = .distantPast
    /// Horloge injectable pour les tests (anti-sautillement).
    public var clockNow: () -> Date = { Date() }

    /// Ordre d'affichage coalescé des sessions visibles (indépendant du groupe).
    private var coalescedSessions: [Session] {
        let visible = displaySessions
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        // Signature structurelle : ensemble d'IDs + rangs d'état (ignore lastEventAt).
        let signature = visible
            .map { "\($0.id.nativeID):\($0.state.sortRank)" }
            .sorted().joined(separator: ",")
        let structural = signature != lastStructuralSignature
        let now = clockNow()
        if structural || now.timeIntervalSince(lastReorderAt) >= 2 || cachedOrder.isEmpty {
            let sorted = visible.sorted(by: Self.intraGroupOrder)
            cachedOrder = sorted.map(\.id)
            lastStructuralSignature = signature
            lastReorderAt = now
            return sorted
        }
        // Réordonnancement lastEventAt-only trop récent → on garde l'ordre précédent,
        // en réinsérant les IDs restants dans l'ordre courant et en appendant les nouveaux.
        var result: [Session] = cachedOrder.compactMap { byID[$0] }
        let known = Set(cachedOrder)
        for session in visible.sorted(by: Self.intraGroupOrder) where !known.contains(session.id) {
            result.append(session)
        }
        return result
    }

    /// Groupes triés (07 · REQ-SES-03) : attention d'abord, puis activité récente,
    /// puis nom ; « Other » toujours en dernier. Tri intra-groupe coalescé (REQ-SES-04/05).
    public var groups: [SessionGroup] {
        let ordered = coalescedSessions
        // Regroupe en préservant l'ordre coalescé au sein de chaque groupe.
        var groupsByKey: [String: [Session]] = [:]
        var keyOrder: [String] = []
        for session in ordered {
            let key = session.projectPath ?? "~other"
            if groupsByKey[key] == nil { keyOrder.append(key) }
            groupsByKey[key, default: []].append(session)
        }
        let built = keyOrder.map { key in
            SessionGroup(id: key, name: groupsByKey[key]?.first?.projectName ?? "Other",
                         sessions: groupsByKey[key] ?? [])
        }
        return built.sorted { a, b in
            if (a.id == "~other") != (b.id == "~other") { return b.id == "~other" }
            let aWaiting = a.sessions.contains { $0.state == .waiting }
            let bWaiting = b.sessions.contains { $0.state == .waiting }
            if aWaiting != bWaiting { return aWaiting }
            let aLast = a.sessions.map(\.lastEventAt).max() ?? .distantPast
            let bLast = b.sessions.map(\.lastEventAt).max() ?? .distantPast
            if aLast != bLast { return aLast > bLast }
            let names = a.name.compare(b.name, options: .caseInsensitive)
            if names != .orderedSame { return names == .orderedAscending }
            return a.id < b.id
        }
    }

    /// Ordre total et stable intra-groupe (07 · REQ-SES-04).
    public static func intraGroupOrder(_ a: Session, _ b: Session) -> Bool {
        if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
        if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return a.id.nativeID < b.id.nativeID
    }

    // MARK: - Transition d'état optimiste sur décision (08 · REQ-ACT-06)

    /// Applique l'état attendu après une décision utilisateur, sans attendre la
    /// corroboration par télémétrie hook (Allow → executing, Deny → thinking…).
    public func applyOptimisticDecision(_ sessionID: SessionID, _ decision: PromptDecision) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        switch decision {
        case .allow, .alwaysAllow, .approvePlan:
            sessions[index].state = .executing
        case .deny, .rejectPlan, .answers, .handInToTerminal:
            sessions[index].state = .thinking
        }
        sessions[index].lastEventAt = Date()
    }

    /// Passe une session en `waiting` à l'arrivée d'un prompt (T5–T7).
    public func markWaiting(_ sessionID: SessionID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].state = .waiting
        sessions[index].lastEventAt = Date()
    }

    // MARK: - Actions (07 · REQ-SES-37..41)

    /// Dismiss : masque la session, données conservées (REQ-SES-41).
    public func dismiss(_ sessionID: SessionID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].isDismissed = true
    }

    /// Marque une session terminée (résultat d'un Kill, REQ-SES-16).
    public func markEnded(_ sessionID: SessionID, reason: SessionEndReason) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].liveness = .ended(reason)
        sessions[index].state = .ended
    }

    public func session(_ id: SessionID) -> Session? {
        sessions.first { $0.id == id }
    }
}

/// Rendu Markdown d'une session pour « Copy Session as Markdown » (07 · REQ-SES-40, 03 · REQ-CLA-78).
public enum SessionMarkdown {
    public static func render(_ session: Session) -> String {
        var lines: [String] = []
        lines.append("# \(session.displayTitle)")
        lines.append("")
        lines.append("- **Agent**: \(session.id.agent.displayName)")
        lines.append("- **Project**: \(session.projectName)")
        if let branch = session.gitBranch { lines.append("- **Branch**: \(branch)") }
        if let model = session.model { lines.append("- **Model**: \(model)") }
        lines.append("- **Host**: \(session.host.label)")
        if !session.tokens.isEmpty {
            lines.append("- **Tokens**: \(DashFormat.tokenChip(session.tokens))")
        }
        if !session.diff.isEmpty {
            lines.append("- **Diff**: +\(session.diff.added) −\(session.diff.removed) across \(session.filesTouched) file(s)")
        }
        lines.append("")
        if !session.timeline.isEmpty {
            lines.append("## Timeline")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for event in session.timeline {
                lines.append("- `\(formatter.string(from: event.timestamp))` \(event.summary)")
            }
            lines.append("")
        }
        if let excerpt = session.lastReplyExcerpt, !excerpt.isEmpty {
            lines.append("## Last reply")
            lines.append(excerpt)
        }
        return lines.joined(separator: "\n")
    }
}
