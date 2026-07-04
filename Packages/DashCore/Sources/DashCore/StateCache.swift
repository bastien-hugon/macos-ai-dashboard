import Foundation

/// Cache d'état persisté (02 · §8, REQ-USG-27) : évite de recalculer au démarrage ce qui
/// est coûteux (stats journalières). Écrit dans Application Support/AgentDash/state/.
/// Tout est reconstructible depuis les transcripts — le cache n'est qu'une accélération.
public struct StateCache: Sendable {
    private let dir: URL

    public init(paths: DashPaths) {
        dir = paths.appSupportDir.appending(path: "state", directoryHint: .isDirectory)
    }

    private var dailyURL: URL { dir.appending(path: "daily-usage.json") }
    private var sessionsURL: URL { dir.appending(path: "sessions-snapshot.json") }

    /// Snapshot des sessions pour un affichage instantané au démarrage (résilience) ;
    /// remplacé par les sources réelles dès qu'elles publient (< 1 s).
    public func saveSessions(_ sessions: [Session]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // On ne persiste pas les timelines volumineuses ni les PID volatils.
        let light = sessions.map { session -> Session in
            var s = session
            s.timeline = []
            s.pid = nil
            s.lastReplyExcerpt = nil
            return s
        }
        guard let data = try? JSONEncoder().encode(light) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    public func loadSessions(maxAgeHours: Double = 48) -> [Session]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sessionsURL.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAgeHours * 3600,
              let data = try? Data(contentsOf: sessionsURL),
              let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
            return nil
        }
        return sessions
    }

    /// Écrit atomiquement le cache des stats journalières.
    public func saveDaily(_ daily: [DailyUsage]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(daily) else { return }
        try? data.write(to: dailyURL, options: .atomic)
    }

    /// Charge le cache des stats journalières (nil si absent/illisible/périmé).
    public func loadDaily(maxAgeHours: Double = 24) -> [DailyUsage]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dailyURL.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAgeHours * 3600,
              let data = try? Data(contentsOf: dailyURL),
              let daily = try? JSONDecoder().decode([DailyUsage].self, from: data) else {
            return nil
        }
        return daily
    }
}
