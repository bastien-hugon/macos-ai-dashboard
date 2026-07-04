import Foundation
import OSLog

/// Logging du produit (01 · §7.3) : OSLog par catégorie, miroir des niveaux `.notice`+
/// vers un fichier tournant exportable. Aucun contenu de prompt/réponse/diff dans les logs —
/// uniquement identifiants, tailles et codes d'erreur (promesse privacy).
public enum DashLog {
    public static let subsystem = "com.agentdash.app"

    public static let hooks = Logger(subsystem: subsystem, category: "hooks")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let claude = Logger(subsystem: subsystem, category: "claude")
    public static let cursor = Logger(subsystem: subsystem, category: "cursor")
    public static let servers = Logger(subsystem: subsystem, category: "servers")
    public static let usage = Logger(subsystem: subsystem, category: "usage")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let doctor = Logger(subsystem: subsystem, category: "doctor")

    /// Miroir fichier — à appeler en plus d'OSLog pour les événements `.notice`+.
    public static func file(_ message: String, category: String = "app") {
        LogSink.shared.append(category: category, message: message)
    }
}

/// Miroir fichier des logs `.notice`+ : `~/Library/Logs/AgentDash/agentdash.log`,
/// rotation 5 × 2 Mo (01 · §7.3).
public final class LogSink: Sendable {
    public static let shared = LogSink()

    private static let maxFileBytes = 2 * 1024 * 1024
    private static let maxRotations = 5

    private let queue = DispatchQueue(label: "com.agentdash.logsink", qos: .utility)
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private init() {}

    nonisolated public func append(category: String, message: String) {
        let line = "\(Date().formatted(Self.timestampStyle)) [\(category)] \(message)\n"
        queue.async { [self] in
            let dir = DashPaths.live().logsDir
            let file = dir.appending(path: "agentdash.log")
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > Self.maxFileBytes {
                rotate(file: file, in: dir)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    private func rotate(file: URL, in dir: URL) {
        let fm = FileManager.default
        let oldest = dir.appending(path: "agentdash.log.\(Self.maxRotations)")
        try? fm.removeItem(at: oldest)
        for i in stride(from: Self.maxRotations - 1, through: 1, by: -1) {
            let from = dir.appending(path: "agentdash.log.\(i)")
            let to = dir.appending(path: "agentdash.log.\(i + 1)")
            try? fm.moveItem(at: from, to: to)
        }
        try? fm.moveItem(at: file, to: dir.appending(path: "agentdash.log.1"))
    }
}
