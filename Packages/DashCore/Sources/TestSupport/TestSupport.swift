import DashCore
import Foundation

/// Horloge pilotable pour les tests (15 · REQ-TST-02) : le temps n'avance que sur demande.
public final class TestClock: ClockProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _monotonic: TimeInterval

    public init(now: Date = Date(timeIntervalSince1970: 1_750_000_000), monotonic: TimeInterval = 0) {
        _now = now
        _monotonic = monotonic
    }

    public var now: Date {
        lock.withLock { _now }
    }

    public var monotonicSeconds: TimeInterval {
        lock.withLock { _monotonic }
    }

    /// Avance les deux horloges (murale + monotone).
    public func advance(by interval: TimeInterval) {
        lock.withLock {
            _now = _now.addingTimeInterval(interval)
            _monotonic += interval
        }
    }

    /// Simule un changement d'horloge murale sans avancer la monotone (test anti-dérive).
    public func setWallClock(_ date: Date) {
        lock.withLock { _now = date }
    }
}

/// Sandbox de home jetable (15 · REQ-TST-01/03/04) : crée une racine isolée dans le
/// répertoire temporaire et fournit le `DashPaths` correspondant.
public enum SandboxHome {
    /// Crée un home jetable et retourne ses chemins. L'appelant est responsable du nettoyage
    /// (ou le laisse au système : tout vit sous le répertoire temporaire).
    public static func create(function: String = #function) throws -> DashPaths {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentdash-tests", directoryHint: .isDirectory)
            .appending(path: "\(function)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = DashPaths(home: root)
        try assertSandboxed(paths)
        return paths
    }

    /// Garde anti-destruction (15 · REQ-TST-04) : aucun test ne peut viser le vrai home.
    public static func assertSandboxed(_ paths: DashPaths) throws {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard paths.home != realHome else {
            throw SandboxError.pointsAtRealHome
        }
    }

    public enum SandboxError: Error {
        case pointsAtRealHome
    }
}

/// Agent factice pour les tests et les aperçus (00 · T3 « AgentFixture »).
public struct AgentFixture: AgentProvider {
    public let kind: AgentKind
    public let capabilities: AgentCapabilities
    public var hooksInstaller: any HooksInstaller { FixtureInstaller(fixedStatus: fixedStatus) }
    private let detected: Bool
    private let fixedStatus: HookInstallStatus

    public init(
        kind: AgentKind = .claude,
        detected: Bool = true,
        status: HookInstallStatus = .ready,
        capabilities: AgentCapabilities? = nil
    ) {
        self.kind = kind
        self.detected = detected
        self.fixedStatus = status
        self.capabilities = capabilities ?? AgentCapabilities(
            supportsAlwaysAllow: kind == .claude,
            supportsInlineQuestions: kind == .claude,
            supportsPlans: kind == .claude,
            usageWindows: kind == .claude ? [.fiveHour, .sevenDay] : [.monthly]
        )
    }

    public func isDetected() -> Bool { detected }

    private struct FixtureInstaller: HooksInstaller {
        let fixedStatus: HookInstallStatus
        func status() async -> HookInstallStatus { fixedStatus }
        func installOrRepair() async throws {}
        func uninstall() async throws {}
    }
}

/// Sessions factices pour les aperçus UI et les tests de tri/agrégation.
public enum SessionFixtures {
    public static func make(
        agent: AgentKind = .claude,
        state: SessionState = .executing,
        title: String = "Refactor the auth flow",
        project: String = "my-project",
        liveness: SessionLiveness = .live
    ) -> Session {
        Session(
            id: SessionID(agent: agent, nativeID: UUID().uuidString),
            state: state,
            liveness: liveness,
            title: title,
            projectPath: "/tmp/\(project)",
            startedAt: Date(timeIntervalSinceNow: -320)
        )
    }
}
