import Foundation
import Observation

// — Serveurs dev (02 · §5) —

public enum FrameworkKind: String, Codable, Sendable {
    case nextjs = "Next.js", vite = "Vite", astro = "Astro", wrangler = "Wrangler"
    case storybook = "Storybook", playwright = "Playwright", staticServer = "Static server"
}

public enum RuntimeKind: String, Codable, Sendable {
    case node = "Node", bun = "Bun", deno = "Deno", python = "Python"
    case ruby = "Ruby", rust = "Rust", go = "Go", other = "—"
}

public enum PackageRunner: String, Codable, Sendable { case npm, pnpm, yarn, bun }

public enum StopState: Equatable, Sendable {
    case none
    case confirming(until: Date)
    case terminating
    case gone
}

public struct DevServer: Identifiable, Sendable, Equatable {
    public struct ID: Hashable, Sendable {
        public let pid: pid_t
        public let port: UInt16
        public init(pid: pid_t, port: UInt16) { self.pid = pid; self.port = port }
    }

    public let id: ID
    public var displayName: String
    public var framework: FrameworkKind?
    public var runtime: RuntimeKind?
    public var packageRunner: PackageRunner?
    public var script: String?
    public var projectPath: String
    public var execPath: String
    public var startTimeSec: UInt64      // pbi_start_tvsec — uptime + garde-fou kill
    public var stopState: StopState

    public init(id: ID, displayName: String, framework: FrameworkKind?, runtime: RuntimeKind?,
                packageRunner: PackageRunner?, script: String?, projectPath: String,
                execPath: String, startTimeSec: UInt64, stopState: StopState = .none) {
        self.id = id
        self.displayName = displayName
        self.framework = framework
        self.runtime = runtime
        self.packageRunner = packageRunner
        self.script = script
        self.projectPath = projectPath
        self.execPath = execPath
        self.startTimeSec = startTimeSec
        self.stopState = stopState
    }

    public var url: URL { URL(string: "http://localhost:\(id.port)")! }
    public var projectName: String { (projectPath as NSString).lastPathComponent }
    public var uptime: TimeInterval {
        max(0, Date().timeIntervalSince1970 - TimeInterval(startTimeSec))
    }
}

/// Store des serveurs dev (10 · §3.6) — mutations sur MainActor.
@MainActor @Observable
public final class ServerStore {
    public private(set) var servers: [DevServer] = []
    public private(set) var isScanning = false

    public init() {}

    public var count: Int { servers.count }

    /// Remplace la liste (résultat d'un scan), en préservant les `stopState` en cours.
    public func applyScan(_ scanned: [DevServer]) {
        let states = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.stopState) })
        servers = scanned.map { server in
            var server = server
            if let previous = states[server.id], previous != .none { server.stopState = previous }
            return server
        }.sorted { $0.id.port < $1.id.port }
        isScanning = false
    }

    public func setScanning() { isScanning = true }

    public func setStopState(_ id: DevServer.ID, _ state: StopState) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].stopState = state
    }
}

// — Quick Routes (11 · §3.1) —

public struct QuickRoute: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    /// Chemins candidats absolus ; seuls les existants s'affichent (résolus hors MainActor).
    public let candidates: [String]
    public let revealsFile: Bool
    public var existing: [String] = []

    public init(id: String, title: String, candidates: [String], revealsFile: Bool = false) {
        self.id = id
        self.title = title
        self.candidates = candidates
        self.revealsFile = revealsFile
    }

    /// Catalogue statique (REQ-QRF-01), scope Claude Code + Cursor.
    public static func catalog(home: String) -> [QuickRoute] {
        [
            QuickRoute(id: "skills", title: "Skills", candidates: ["\(home)/.claude/skills", "\(home)/.cursor/skills-cursor"]),
            QuickRoute(id: "plugins", title: "Plugins", candidates: ["\(home)/.claude/plugins", "\(home)/.cursor/plugins"]),
            QuickRoute(id: "config", title: "Config", candidates: ["\(home)/.claude/settings.json"], revealsFile: true),
            QuickRoute(id: "logs", title: "Logs", candidates: ["\(home)/.claude/projects"]),
            QuickRoute(id: "hooks", title: "Hooks", candidates: ["\(home)/.cursor/hooks.json"], revealsFile: true),
            QuickRoute(id: "mcp", title: "MCP", candidates: ["\(home)/.claude/plugins", "\(home)/.cursor/mcp.json"], revealsFile: true),
            QuickRoute(id: "root", title: "Root", candidates: ["\(home)/.claude", "\(home)/.cursor"]),
        ]
    }
}

// — Fast Actions (02 · §5, feature v0.2.5) —

public struct FastAction: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var command: String
    public var workingDirectory: String?
    public var lastRunAt: Date?
    public var lastExitCode: Int32?

    public init(id: UUID = UUID(), title: String, command: String, workingDirectory: String? = nil) {
        self.id = id
        self.title = title
        self.command = command
        self.workingDirectory = workingDirectory
    }
}

/// Store des Fast Actions — persisté en UserDefaults (JSON).
@MainActor @Observable
public final class FastActionStore {
    public private(set) var actions: [FastAction] = []
    private let defaults: UserDefaults
    private static let key = "agentdash.fastActions"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([FastAction].self, from: data) {
            actions = decoded
        }
    }

    public func upsert(_ action: FastAction) {
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        persist()
    }

    public func remove(_ id: UUID) {
        actions.removeAll { $0.id == id }
        persist()
    }

    public func recordRun(_ id: UUID, exitCode: Int32) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[index].lastRunAt = Date()
        actions[index].lastExitCode = exitCode
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(actions) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
