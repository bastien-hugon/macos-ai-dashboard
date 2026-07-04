import DashCore
import Foundation

/// Installe/répare les hooks AgentDash dans `~/.cursor/hooks.json` (04 · REQ-CUR, research
/// cursor §1.1). Le fichier n'existe pas par défaut : on le crée (version 1) ou on le fusionne.
/// Fail-open partout (jamais `failClosed`).
public struct CursorHooksInstaller: HooksInstaller {
    private let paths: DashPaths
    private var hookCommand: String { paths.hookBinary.path }

    public init(paths: DashPaths) {
        self.paths = paths
    }

    /// Événements « décision » (permissions) + télémétrie utiles au produit.
    private static let events = [
        "beforeShellExecution", "beforeMCPExecution",
        "afterFileEdit", "beforeSubmitPrompt", "stop",
        "sessionStart", "sessionEnd", "afterShellExecution",
    ]

    public func status() async -> HookInstallStatus {
        guard FileManager.default.fileExists(atPath: paths.cursorDir.path) else {
            return .agentNotDetected
        }
        guard let config = read() else { return .notInstalled }
        let hooks = config["hooks"] as? [String: Any] ?? [:]
        for event in Self.events {
            let entries = hooks[event] as? [[String: Any]] ?? []
            if !entries.contains(where: { ($0["command"] as? String)?.contains(hookCommand) == true }) {
                return .notInstalled
            }
        }
        return .ready
    }

    public func installOrRepair() async throws {
        guard FileManager.default.fileExists(atPath: paths.cursorDir.path) else {
            throw InstallerError.agentNotDetected
        }
        var config = read() ?? ["version": 1]
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        for event in Self.events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { ($0["command"] as? String)?.contains(hookCommand) == true }
            entries.append(["command": "\(hookCommand) --source cursor"])
            hooks[event] = entries
        }
        config["hooks"] = hooks
        config["version"] = config["version"] ?? 1
        try backupIfNeeded()
        try writeAtomic(config)
    }

    public func uninstall() async throws {
        guard var config = read(), var hooks = config["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { ($0["command"] as? String)?.contains(hookCommand) == true }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = hooks }
        try writeAtomic(config)
    }

    // MARK: -

    private func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.cursorHooks),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private func backupIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: paths.cursorHooks.path) else { return }
        let dir = paths.agentDashDir.appending(path: "backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = dir.appending(path: "cursor-hooks.json.\(stamp).bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: paths.cursorHooks, to: backup)
        }
    }

    private func writeAtomic(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmp = paths.cursorHooks.deletingLastPathComponent().appending(path: ".hooks.json.agentdash.tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(paths.cursorHooks, withItemAt: tmp)
    }

    enum InstallerError: Error { case agentNotDetected }
}
