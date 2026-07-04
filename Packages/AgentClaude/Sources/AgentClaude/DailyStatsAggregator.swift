import DashCore
import Foundation

/// Agrège les stats journalières Claude depuis les transcripts locaux (09 · REQ-USG-24/27) :
/// somme des `message.usage` des entrées `assistant`, dédupliquées par `requestId` (dernière
/// entrée gardée — streaming cumulatif). Tourne en tâche de fond, jamais sur MainActor.
public actor DailyStatsAggregator {
    private let paths: DashPaths
    private let days: Int

    public init(paths: DashPaths, days: Int = 14) {
        self.paths = paths
        self.days = days
    }

    private struct Sample { var input = 0, output = 0, cacheRead = 0, cacheCreation = 0; var model = "" }

    public func aggregate(now: Date = Date()) -> [DailyUsage] {
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        // clé jour → (requestId → sample) pour dédup globale par requête.
        var byDay: [String: [String: Sample]] = [:]
        var sessionsByDay: [String: Set<String>] = [:]

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: paths.claudeProjectsDir,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return [] }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", !url.path.contains("/subagents/") else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard mtime >= cutoff else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.readToEnd() else { continue }

            for lineData in data.split(separator: 0x0A) {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                      entry["type"] as? String == "assistant",
                      entry["isSidechain"] as? Bool != true,
                      let message = entry["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let timestamp = (entry["timestamp"] as? String).flatMap(TranscriptAccumulator.parseTimestamp),
                      timestamp >= cutoff else { continue }
                let dayKey = Self.dayKey(timestamp, calendar: calendar)
                let requestKey = entry["requestId"] as? String ?? message["id"] as? String ?? UUID().uuidString
                var sample = Sample()
                sample.input = usage["input_tokens"] as? Int ?? 0
                sample.output = usage["output_tokens"] as? Int ?? 0
                sample.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                sample.cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
                sample.model = message["model"] as? String ?? ""
                byDay[dayKey, default: [:]][requestKey] = sample // dernière entrée du requestId
                if let session = entry["sessionId"] as? String {
                    sessionsByDay[dayKey, default: []].insert(session)
                }
            }
        }

        return byDay.map { dayKey, samples in
            var tally = TokenTally()
            var cost = 0.0
            for sample in samples.values {
                tally.inputTokens += sample.input
                tally.outputTokens += sample.output
                tally.cacheReadTokens += sample.cacheRead
                tally.cacheCreationTokens += sample.cacheCreation
                cost += ModelPricing.cost(model: sample.model, input: sample.input,
                                          output: sample.output, cacheRead: sample.cacheRead,
                                          cacheCreation: sample.cacheCreation)
            }
            return DailyUsage(
                id: "\(dayKey)|claude",
                date: Self.dateFromKey(dayKey, calendar: calendar) ?? now,
                agent: .claude, tokens: tally, costUSD: cost,
                sessionCount: sessionsByDay[dayKey]?.count ?? 0
            )
        }.sorted { $0.date > $1.date }
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func dateFromKey(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents(); c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return calendar.date(from: c)
    }
}

/// Table de prix statique par modèle (style LiteLLM, USD par token) — coût estimé (REQ-USG-25).
enum ModelPricing {
    // (input, output, cacheRead, cacheWrite) en USD par million de tokens.
    private static let table: [(prefix: String, input: Double, output: Double, cacheRead: Double, cacheWrite: Double)] = [
        ("claude-opus", 15, 75, 1.5, 18.75),
        ("claude-fable", 15, 75, 1.5, 18.75),
        ("claude-sonnet", 3, 15, 0.3, 3.75),
        ("claude-haiku", 0.8, 4, 0.08, 1),
    ]

    static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheCreation: Int) -> Double {
        let row = table.first { model.hasPrefix($0.prefix) } ?? table[0]
        let m = 1_000_000.0
        return Double(input) / m * row.input
            + Double(output) / m * row.output
            + Double(cacheRead) / m * row.cacheRead
            + Double(cacheCreation) / m * row.cacheWrite
    }
}
