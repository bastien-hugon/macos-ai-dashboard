import DashCore
import Foundation

/// Installe/répare/désinstalle les hooks AgentDash dans `~/.claude/settings.json`
/// (03 · REQ-CLA-01..08). Fusion **non destructive** : les hooks tiers sont préservés,
/// seules les entrées portant le marqueur AgentDash (chemin du binaire) sont gérées.
/// Écriture atomique + sauvegarde `.bak` avant la première modification.
public struct ClaudeHooksInstaller: HooksInstaller {
    private let paths: DashPaths
    /// Chemin du binaire inscrit dans settings.json (marqueur d'identification de nos entrées).
    private var hookCommand: String { paths.hookBinary.path }

    public init(paths: DashPaths) {
        self.paths = paths
    }

    // MARK: - Jeu de hooks (01 · §4.2)

    /// (événement, matcher optionnel, timeout). Sous-ensemble M2 : décision + télémétrie
    /// nécessaires au « Act » et au cycle de vie.
    private static let hookSpec: [(event: String, matcher: String?, timeout: Int)] = [
        ("PermissionRequest", "*", 600),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode", 600),
        ("PreToolUse", "*", 5),
        ("PostToolUse", "*", 5),
        ("Stop", nil, 5),
        ("Notification", nil, 5),
        ("SessionStart", nil, 5),
        ("SessionEnd", nil, 5),
        ("ConfigChange", "user_settings", 5),
    ]

    // MARK: - Statut

    public func status() async -> HookInstallStatus {
        guard FileManager.default.fileExists(atPath: paths.claudeDir.path) else {
            return .agentNotDetected
        }
        guard FileManager.default.fileExists(atPath: paths.hookBinary.path) else {
            return .damaged(reason: "hook binary missing")
        }
        guard let settings = readSettings() else { return .notInstalled }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        for spec in Self.hookSpec {
            let entries = hooks[spec.event] as? [[String: Any]] ?? []
            if !entries.contains(where: { containsOurHook($0) }) {
                return .notInstalled
            }
        }
        return .ready
    }

    // MARK: - Installation / réparation (idempotent)

    public func installOrRepair() async throws {
        guard FileManager.default.fileExists(atPath: paths.claudeDir.path) else {
            throw InstallerError.agentNotDetected
        }
        var settings = readSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for spec in Self.hookSpec {
            var entries = hooks[spec.event] as? [[String: Any]] ?? []
            // Retirer nos anciennes entrées (réparation), garder les tierces (REQ-CLA-02).
            entries.removeAll { containsOurHook($0) }
            entries.append(makeEntry(matcher: spec.matcher, timeout: spec.timeout))
            hooks[spec.event] = entries
        }
        settings["hooks"] = hooks

        try backupIfFirstWrite()
        try writeAtomic(settings)
        DashLog.claude.notice("hooks Claude installés/réparés")
    }

    public func uninstall() async throws {
        guard var settings = readSettings(),
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { containsOurHook($0) }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeAtomic(settings)
        DashLog.claude.notice("hooks Claude désinstallés")
    }

    // MARK: - Détails

    private func makeEntry(matcher: String?, timeout: Int) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "\(hookCommand) --source claude",
                "timeout": timeout,
            ]],
        ]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    private func containsOurHook(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String)?.contains(hookCommand) == true }
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: paths.claudeSettings),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func backupIfFirstWrite() throws {
        let backupsDir = paths.agentDashDir.appending(path: "backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: paths.claudeSettings.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = backupsDir.appending(path: "settings.json.\(stamp).bak")
        // Une seule sauvegarde par installation (pas d'écrasement d'une antérieure).
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: paths.claudeSettings, to: backup)
        }
    }

    private func writeAtomic(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let tmp = paths.claudeSettings.deletingLastPathComponent()
            .appending(path: ".settings.json.agentdash.tmp")
        try data.write(to: tmp)
        // rename atomique
        _ = try FileManager.default.replaceItemAt(paths.claudeSettings, withItemAt: tmp)
    }

    enum InstallerError: Error { case agentNotDetected }
}
