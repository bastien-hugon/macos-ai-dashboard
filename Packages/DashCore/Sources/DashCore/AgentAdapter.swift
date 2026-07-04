import Foundation

/// Capacités déclaratives d'un agent (00 · REQ-VIS-10) : l'UI ne teste jamais `AgentKind`
/// pour activer une feature, elle interroge les capacités du provider.
public struct AgentCapabilities: Sendable {
    public var supportsAlwaysAllow: Bool
    public var supportsInlineQuestions: Bool
    public var supportsPlans: Bool
    public var usageWindows: [UsageWindowKind]

    public init(
        supportsAlwaysAllow: Bool,
        supportsInlineQuestions: Bool,
        supportsPlans: Bool,
        usageWindows: [UsageWindowKind]
    ) {
        self.supportsAlwaysAllow = supportsAlwaysAllow
        self.supportsInlineQuestions = supportsInlineQuestions
        self.supportsPlans = supportsPlans
        self.usageWindows = usageWindows
    }
}

public enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    case fiveHour        // Claude — court terme
    case sevenDay        // Claude — long terme
    case sevenDayOpus    // Claude — sous-fenêtre modèle (vue détail)
    case sevenDaySonnet  // Claude — sous-fenêtre modèle (vue détail)
    case monthly         // Cursor — cycle de facturation

    /// Fenêtres affichées dans le résumé (les sous-fenêtres modèle restent en détail).
    public static let summaryClaude: [UsageWindowKind] = [.fiveHour, .sevenDay]
}

/// Statut d'installation des hooks d'un agent (03/04, affiché « Ready » dans Settings).
public enum HookInstallStatus: Equatable, Sendable {
    case ready
    case notInstalled
    case damaged(reason: String)
    case agentNotDetected
}

/// Installeur/réparateur de hooks d'un agent (contrat normatif : 00 · §3.2).
/// Les écritures sont non destructives et réversibles (01 · §8.5) : fusion avec marqueur,
/// sauvegarde `.bak` horodatée avant première écriture, désinstallation = retrait de nos entrées.
public protocol HooksInstaller: Sendable {
    func status() async -> HookInstallStatus
    func installOrRepair() async throws
    func uninstall() async throws
}

/// Un agent branché à AgentDash (Claude Code, Cursor — Codex possible plus tard).
public protocol AgentProvider: Sendable {
    var kind: AgentKind { get }
    var capabilities: AgentCapabilities { get }
    var hooksInstaller: any HooksInstaller { get }
    /// L'agent est-il présent sur la machine (dossier de config existant) ?
    func isDetected() -> Bool
}

/// Fournisseur d'usage (fenêtres 5 h/7 j/mensuel) — implémenté par AgentClaude/AgentCursor,
/// consommé par UsageKit via injection (09 · §3.1).
public protocol UsageProvider: Sendable {
    var agent: AgentKind { get }
    func discoverAccounts() async throws -> [UsageAccount]
    func fetchUsage() async throws -> UsageSnapshot
}

public enum UsageError: Error, Sendable, Equatable {
    case network(String)
    case unauthorized          // 401 après relecture Keychain
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(field: String?)
    case accountUnavailable    // Keychain refusé, credentials absents…
}
