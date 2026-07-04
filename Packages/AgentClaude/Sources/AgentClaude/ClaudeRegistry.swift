import DashCore
import Darwin
import Foundation

/// Entrée du registre des sessions vivantes `~/.claude/sessions/<pid>.json`
/// (research claude-code §3.1, 03 · REQ-CLA-71).
struct RegistryEntry: Sendable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let startedAt: Date?
    let entrypoint: String?
    let name: String?
}

enum ClaudeRegistry {
    /// Lit le registre en ne gardant que les entrées dont le PID est vivant
    /// (orphelins de crash ignorés, 03 · REQ-CLA-72). Clé du résultat : sessionId.
    static func loadLiveEntries(from directory: URL) -> [String: RegistryEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var result: [String: RegistryEntry] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any],
                  let pid = (dict["pid"] as? NSNumber)?.int32Value,
                  let sessionId = dict["sessionId"] as? String,
                  kill(pid, 0) == 0 else { continue }
            let entry = RegistryEntry(
                pid: pid,
                sessionId: sessionId,
                cwd: dict["cwd"] as? String,
                startedAt: (dict["startedAt"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                entrypoint: dict["entrypoint"] as? String,
                name: dict["name"] as? String
            )
            // Deux fichiers PID de même sessionId (resume ailleurs) → le plus récent gagne.
            if let existing = result[sessionId],
               (existing.startedAt ?? .distantPast) > (entry.startedAt ?? .distantPast) {
                continue
            }
            result[sessionId] = entry
        }
        return result
    }
}

/// Résolution de l'environnement hôte (03 · REQ-CLA-70, 07 · REQ-SES-26) :
/// `entrypoint` d'abord, puis remontée de l'arbre des process pour étiqueter le terminal.
enum HostResolver {
    static func resolve(entrypoint: String?, pid: Int32?) -> SessionHost {
        switch entrypoint {
        case "claude-desktop-3p":
            return .desktopApp
        case "claude-vscode":
            // Extension IDE : distinguer Cursor / VS Code par le process ancêtre.
            if let app = ancestorApp(of: pid) {
                return .ide(app)
            }
            return .ide("IDE")
        default:
            if let app = ancestorApp(of: pid) {
                return app == "Cursor" || app == "VS Code" ? .ide(app) : .terminal(app)
            }
            return entrypoint == nil ? .unknown : .terminal(nil)
        }
    }

    /// Remonte les parents (10 niveaux max) et mappe le premier nom d'app connu.
    static func ancestorApp(of pid: Int32?) -> String? {
        guard var current = pid else { return nil }
        let known: [String: String] = [
            "iTerm2": "iTerm", "iTerm": "iTerm",
            "Terminal": "Terminal",
            "warp": "Warp", "stable": "Warp",
            "ghostty": "Ghostty",
            "kitty": "kitty", "alacritty": "Alacritty", "WezTerm": "WezTerm",
            "Cursor": "Cursor",
            "Code": "VS Code", "Code Helper": "VS Code", "Electron": "VS Code",
            "Claude": "Desktop",
        ]
        for _ in 0..<10 {
            guard current > 1 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let written = proc_pidpath(current, &buffer, UInt32(buffer.count))
            guard written > 0 else { return nil }
            let path = String(decoding: buffer[..<Int(written)], as: UTF8.self)
            let name = (path as NSString).lastPathComponent
            for (needle, label) in known where name.hasPrefix(needle) {
                return label
            }
            current = parentPID(of: current) ?? -1
        }
        return nil
    }

    static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
