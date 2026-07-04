import Foundation

/// Agent supporté. Codex est hors scope (AGENTPEEK_FEATURES §14) mais l'architecture
/// reste extensible : tout passe par les protocoles AgentAdapter.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case cursor

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        }
    }
}

/// État d'une session (02 · §3). `waiting` n'est atteint que sur signal explicite
/// (prompt en attente), jamais par timeout — un outil long reste `executing`.
public enum SessionState: String, Codable, Sendable {
    case executing
    case thinking
    case waiting
    case idle
    case ended

    /// Priorité d'agrégation pour l'indicateur du pill : waiting > executing > thinking > idle.
    public var attentionPriority: Int {
        switch self {
        case .waiting: 4
        case .executing: 3
        case .thinking: 2
        case .idle: 1
        case .ended: 0
        }
    }

    /// Rang de tri intra-groupe (07 · REQ-SES-04) : waiting = 0 … ended = 4.
    public var sortRank: Int {
        switch self {
        case .waiting: 0
        case .executing: 1
        case .thinking: 2
        case .idle: 3
        case .ended: 4
        }
    }
}

/// Identité stable d'une session : (agent, id natif — sessionId Claude / composerId Cursor).
public struct SessionID: Hashable, Codable, Sendable {
    public let agent: AgentKind
    public let nativeID: String

    public init(agent: AgentKind, nativeID: String) {
        self.agent = agent
        self.nativeID = nativeID
    }
}

/// Environnement hôte d'une session (07 · REQ-SES-26).
public enum SessionHost: Hashable, Sendable {
    case terminal(String?) // TERM_PROGRAM si connu
    case ide(String)       // « Cursor », « VS Code »
    case desktopApp
    case unknown

    public var label: String {
        switch self {
        case .terminal(let program): program ?? "Terminal"
        case .ide(let name): name
        case .desktopApp: "Desktop"
        case .unknown: "—"
        }
    }
}

public enum SessionEndReason: Hashable, Sendable {
    case exited, cleared, killed

    public var label: String {
        switch self {
        case .exited: "Ended"
        case .cleared: "Cleared"
        case .killed: "Killed"
        }
    }
}

/// Cycle de vie (02 · §3) : une session terminée reste listée jusqu'au GC (24 h).
public enum SessionLiveness: Hashable, Sendable {
    case live
    case ended(SessionEndReason)

    public var isLive: Bool { if case .live = self { true } else { false } }
}

/// Comptage de tokens par session, split input/output, dédupliqué par requête
/// (03 · REQ-CLA-24). Le total de consommation inclut les caches (piège ×100).
public struct TokenTally: Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    public var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 }
    /// Consommation réelle côté input (caches inclus, 03 · REQ-CLA-24).
    public var totalInputConsumption: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
}

public struct DiffStats: Hashable, Sendable {
    public var added: Int
    public var removed: Int

    public init(added: Int = 0, removed: Int = 0) {
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { added == 0 && removed == 0 }
}

/// Événement de timeline (07 · REQ-SES-30..36) — résumé en langage clair, jamais
/// le contenu brut (budget RAM, 01 · §6).
public struct TimelineEvent: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case prompt, toolCall, reply, marker, subagent
    }

    public let id: String
    public let timestamp: Date
    public let kind: Kind
    public let summary: String

    public init(id: String, timestamp: Date, kind: Kind, summary: String) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.summary = summary
    }
}

/// Session d'agent (02 · §2) — champs M1 ; enrichie aux jalons M2+ (prompts, compte).
public struct Session: Identifiable, Hashable, Sendable {
    public let id: SessionID
    public var state: SessionState
    public var liveness: SessionLiveness
    public var title: String
    public var projectPath: String?
    public var startedAt: Date
    public var lastEventAt: Date
    public var host: SessionHost
    public var tokens: TokenTally
    public var diff: DiffStats
    public var filesTouched: Int
    public var commandCount: Int
    public var gitBranch: String?
    public var model: String?
    public var pid: Int32?
    /// Résumé du dernier événement, en langage clair (07 · REQ-SES-20).
    public var lastActivity: String?
    /// Extrait de la dernière réponse assistant (Markdown source, 03 · REQ-CLA-26).
    public var lastReplyExcerpt: String?
    /// Fenêtre récente de timeline (le plein historique est relu à la demande, 01 · §6).
    public var timeline: [TimelineEvent]
    public var subagentCount: Int
    public var isDismissed: Bool
    /// % de la fenêtre de contexte utilisé (Cursor : contextUsagePercent). Chip « ctx 72% ».
    public var contextPercent: Double?

    public init(
        id: SessionID,
        state: SessionState = .idle,
        liveness: SessionLiveness = .live,
        title: String = "",
        projectPath: String? = nil,
        startedAt: Date,
        lastEventAt: Date? = nil,
        host: SessionHost = .unknown,
        tokens: TokenTally = TokenTally(),
        diff: DiffStats = DiffStats(),
        filesTouched: Int = 0,
        commandCount: Int = 0,
        gitBranch: String? = nil,
        model: String? = nil,
        pid: Int32? = nil,
        lastActivity: String? = nil,
        lastReplyExcerpt: String? = nil,
        timeline: [TimelineEvent] = [],
        subagentCount: Int = 0,
        isDismissed: Bool = false,
        contextPercent: Double? = nil
    ) {
        self.id = id
        self.state = state
        self.liveness = liveness
        self.title = title
        self.projectPath = projectPath
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt ?? startedAt
        self.host = host
        self.tokens = tokens
        self.diff = diff
        self.filesTouched = filesTouched
        self.commandCount = commandCount
        self.gitBranch = gitBranch
        self.model = model
        self.pid = pid
        self.lastActivity = lastActivity
        self.lastReplyExcerpt = lastReplyExcerpt
        self.timeline = timeline
        self.subagentCount = subagentCount
        self.isDismissed = isDismissed
        self.contextPercent = contextPercent
    }

    /// Nom du projet = basename du chemin (07 · REQ-SES-02).
    public var projectName: String {
        guard let projectPath, !projectPath.isEmpty else { return "Other" }
        return (projectPath as NSString).lastPathComponent
    }

    public var displayTitle: String {
        title.isEmpty ? projectName : title
    }

    /// Graine stable de l'avatar pixel-grid (07 · REQ-SES-17).
    public var avatarSeed: UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037 // FNV-1a
        for byte in "\(id.agent.rawValue):\(id.nativeID)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}
