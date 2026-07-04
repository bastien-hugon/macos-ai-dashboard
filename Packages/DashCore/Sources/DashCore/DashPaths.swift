import Foundation

/// Racine unique de tous les accès disque du produit (15 · REQ-TST-01).
/// Aucun module ne doit construire un chemin à partir de `NSHomeDirectory()` directement :
/// tout dérive d'une racine `home` injectable, ce qui rend l'ensemble sandboxable en test.
/// En build Debug, la variable d'environnement `AGENTDASH_HOME` remplace la racine ;
/// en Release elle est ignorée (anti-abus).
public struct DashPaths: Equatable, Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    /// Instance de production : vrai home de l'utilisateur, override d'environnement en Debug.
    public static func live() -> DashPaths {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["AGENTDASH_HOME"], !override.isEmpty {
            return DashPaths(home: URL(fileURLWithPath: override, isDirectory: true))
        }
        #endif
        return DashPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - Agents

    public var claudeDir: URL { home.appending(path: ".claude", directoryHint: .isDirectory) }
    public var claudeSettings: URL { claudeDir.appending(path: "settings.json") }
    public var claudeProjectsDir: URL { claudeDir.appending(path: "projects", directoryHint: .isDirectory) }
    public var claudeSessionsDir: URL { claudeDir.appending(path: "sessions", directoryHint: .isDirectory) }

    public var cursorDir: URL { home.appending(path: ".cursor", directoryHint: .isDirectory) }
    public var cursorHooks: URL { cursorDir.appending(path: "hooks.json") }
    public var cursorGlobalStorageDB: URL {
        home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    // MARK: - AgentDash

    public var agentDashDir: URL { home.appending(path: ".agentdash", directoryHint: .isDirectory) }
    public var hookBinaryDir: URL { agentDashDir.appending(path: "bin", directoryHint: .isDirectory) }
    public var hookBinary: URL { hookBinaryDir.appending(path: "agentdash-hook") }

    public var appSupportDir: URL {
        home.appending(path: "Library/Application Support/AgentDash", directoryHint: .isDirectory)
    }

    /// Socket IPC (01 · §1). `AGENTDASH_SOCKET_OVERRIDE` (Debug) permet aux tests d'intégration
    /// d'isoler leur canal ; repli `$TMPDIR` si le chemin dépasse la limite `sun_path` (104 octets).
    public var socketPath: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["AGENTDASH_SOCKET_OVERRIDE"], !override.isEmpty {
            return override
        }
        #endif
        let preferred = appSupportDir.appending(path: "agentdash.sock").path
        if preferred.utf8.count < 100 { return preferred }
        return NSTemporaryDirectory() + "agentdash.sock"
    }

    public var logsDir: URL { home.appending(path: "Library/Logs/AgentDash", directoryHint: .isDirectory) }
}
