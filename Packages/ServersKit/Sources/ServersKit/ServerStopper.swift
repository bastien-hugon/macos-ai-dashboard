import Darwin
import DashCore
import Foundation

/// Arrêt sécurisé d'un serveur (10 · §3.5) : re-validation complète du process avant tout
/// signal (anti-réutilisation de PID), SIGTERM → 3 s → SIGKILL. Jamais `killpg`.
public enum ServerStopper {
    public enum Outcome: Equatable, Sendable {
        case terminated
        case alreadyGone
        case stillAlive
        case refused(reason: String)
    }

    /// Garde-fous purs (testables) — 01 · §8.4.
    public static func validate(pid: pid_t, expectedStartTimeSec: UInt64, expectedExecPath: String) -> String? {
        guard pid >= 100 else { return "PID système (< 100)" }
        guard pid != getpid() else { return "processus AgentDash" }

        var bsdInfo = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else {
            return nil // déjà parti : l'appelant traite alreadyGone via kill(pid,0)
        }
        guard bsdInfo.pbi_uid == getuid() else { return "processus d'un autre utilisateur" }
        guard bsdInfo.pbi_start_tvsec == expectedStartTimeSec else { return "PID réutilisé (start time)" }

        var pathBuffer = [UInt8](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if len > 0 {
            let path = String(decoding: pathBuffer[..<Int(len)], as: UTF8.self)
            guard path == expectedExecPath else { return "PID réutilisé (exec path)" }
        }
        return nil
    }

    public static func stop(pid: pid_t, startTimeSec: UInt64, execPath: String) async -> Outcome {
        if kill(pid, 0) != 0 { return .alreadyGone }
        if let reason = validate(pid: pid, expectedStartTimeSec: startTimeSec, expectedExecPath: execPath) {
            return .refused(reason: reason)
        }
        guard kill(pid, SIGTERM) == 0 else { return .alreadyGone }
        // Sonde 15 × 200 ms.
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if kill(pid, 0) != 0 { return .terminated }
        }
        _ = kill(pid, SIGKILL)
        try? await Task.sleep(for: .seconds(1))
        return kill(pid, 0) != 0 ? .terminated : .stillAlive
    }
}

/// Construit les `DevServer` complets à partir d'un scan (scan → identités → classification).
public enum ServerBuilder {
    public static func build() -> [DevServer] {
        let listeners = PortScanner.scan()
        var identities: [pid_t: ProcessIdentity] = [:]
        var results: [DevServer] = []

        for listener in listeners {
            let identity: ProcessIdentity
            if let cached = identities[listener.pid] {
                identity = cached
            } else if let fresh = ServerIdentifier.identify(pid: listener.pid) {
                identities[listener.pid] = fresh
                identity = fresh
            } else {
                continue
            }
            let classification = ServerIdentifier.classify(identity)
            let projectPath = identity.cwd == "/" ? identity.execPath : identity.cwd
            results.append(DevServer(
                id: DevServer.ID(pid: listener.pid, port: listener.port),
                displayName: classification.displayName,
                framework: classification.framework,
                runtime: classification.runtime,
                packageRunner: classification.packageRunner,
                script: classification.script,
                projectPath: projectPath,
                execPath: identity.execPath,
                startTimeSec: identity.startTimeSec
            ))
        }
        return results
    }
}
