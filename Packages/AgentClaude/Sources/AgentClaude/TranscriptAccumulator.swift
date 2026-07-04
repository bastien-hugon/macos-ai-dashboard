import DashCore
import Foundation

/// Accumulateur d'état par transcript JSONL (03 · REQ-CLA-21..27).
/// Parseur tolérant : une ligne illisible ou d'un type inconnu est ignorée sans erreur.
/// Ne conserve jamais les inputs complets ni les gros tool_result (budget 01 · §6) —
/// uniquement des résumés en langage clair.
struct TranscriptAccumulator {
    static let timelineCap = 200
    static let replyExcerptCap = 4000

    private struct UsageSample {
        var input: Int, output: Int, cacheRead: Int, cacheCreation: Int
    }

    let filePath: String
    var sessionId: String
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    var title: String?
    var model: String?
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var lastWriteAt: Date
    var subagentFiles: Set<String> = []

    private var usageByRequest: [String: UsageSample] = [:]
    private(set) var pendingToolUses: [String: String] = [:] // tool_use_id → résumé
    private var touchedFiles: Set<String> = []
    private(set) var commandCount = 0
    private(set) var diff = DiffStats()
    private(set) var timeline: [TimelineEvent] = []
    private(set) var lastActivity: String?
    private(set) var lastReplyText = ""
    private(set) var lastEntryIsAssistant = false
    private(set) var lastStopReasonIsNull = false

    init(filePath: String, now: Date) {
        self.filePath = filePath
        // Nom de fichier = sessionId (research claude-code §3.1) ; corrigé par les entrées.
        self.sessionId = URL(fileURLWithPath: filePath)
            .deletingPathExtension().lastPathComponent
        self.lastWriteAt = now
    }

    var filesTouchedCount: Int { touchedFiles.count }

    var tokens: TokenTally {
        var tally = TokenTally()
        for sample in usageByRequest.values {
            tally.inputTokens += sample.input
            tally.outputTokens += sample.output
            tally.cacheReadTokens += sample.cacheRead
            tally.cacheCreationTokens += sample.cacheCreation
        }
        return tally
    }

    // MARK: - Ingestion ligne à ligne

    mutating func ingest(line: some StringProtocol, now: Date) {
        lastWriteAt = now
        guard line.count > 1,
              let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let entry = object as? [String: Any],
              let type = entry["type"] as? String else { return }

        if let id = entry["sessionId"] as? String { sessionId = id }
        if let value = entry["cwd"] as? String { cwd = value }
        if let value = entry["gitBranch"] as? String, !value.isEmpty { gitBranch = value }
        if let value = entry["entrypoint"] as? String { entrypoint = value }
        let timestamp = (entry["timestamp"] as? String).flatMap(Self.parseTimestamp)
        if let timestamp {
            if firstTimestamp == nil { firstTimestamp = timestamp }
            lastTimestamp = timestamp
        }
        // Les entrées sidechain n'alimentent jamais une session racine (REQ-CLA-25).
        if entry["isSidechain"] as? Bool == true { return }

        switch type {
        case "user": ingestUser(entry, at: timestamp ?? now)
        case "assistant": ingestAssistant(entry, at: timestamp ?? now)
        case "ai-title":
            if let value = entry["aiTitle"] as? String, !value.isEmpty { title = value }
        default:
            break // type inconnu ou sans intérêt : toléré (REQ-CLA-21)
        }
    }

    private mutating func ingestUser(_ entry: [String: Any], at timestamp: Date) {
        let message = entry["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]] ?? []

        // Résultat de tool : appariement par tool_use_id (REQ-CLA-22).
        if let result = content.first(where: { $0["type"] as? String == "tool_result" }) {
            if let toolUseID = result["tool_use_id"] as? String {
                pendingToolUses.removeValue(forKey: toolUseID)
            }
            ingestToolResult(entry)
            lastEntryIsAssistant = false
            return
        }

        // Prompt utilisateur : nouveau tour → reset de l'extrait de réponse.
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        if !text.isEmpty, entry["isMeta"] as? Bool != true {
            lastReplyText = ""
            appendEvent(kind: .prompt, summary: Self.truncate("Prompt: " + text, 90),
                        id: entry["uuid"] as? String, at: timestamp)
        }
        lastEntryIsAssistant = false
    }

    private mutating func ingestToolResult(_ entry: [String: Any]) {
        // Diffs : structuredPatch des résultats Edit/Write (REQ-CLA-23).
        guard let result = entry["toolUseResult"] as? [String: Any] else { return }
        if let patches = result["structuredPatch"] as? [[String: Any]] {
            for hunk in patches {
                for line in hunk["lines"] as? [String] ?? [] {
                    if line.hasPrefix("+") { diff.added += 1 }
                    else if line.hasPrefix("-") { diff.removed += 1 }
                }
            }
        }
        if let filePath = result["filePath"] as? String { touchedFiles.insert(filePath) }
    }

    private mutating func ingestAssistant(_ entry: [String: Any], at timestamp: Date) {
        lastEntryIsAssistant = true
        guard let message = entry["message"] as? [String: Any] else { return }
        if let value = message["model"] as? String { model = value }
        lastStopReasonIsNull = message["stop_reason"] is NSNull || message["stop_reason"] == nil

        // Tokens : dédup par requestId, garder la dernière entrée (streaming cumulatif,
        // REQ-CLA-24) ; caches inclus dans la consommation.
        if let usage = message["usage"] as? [String: Any] {
            let key = entry["requestId"] as? String
                ?? message["id"] as? String
                ?? entry["uuid"] as? String
                ?? UUID().uuidString
            usageByRequest[key] = UsageSample(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0
            )
        }

        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String {
                    lastReplyText = Self.truncate(lastReplyText + text, Self.replyExcerptCap)
                }
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let summary = Self.summarizeToolUse(name: name, input: input)
                if let id = block["id"] as? String { pendingToolUses[id] = summary }
                trackCounters(toolName: name, input: input)
                appendEvent(kind: .toolCall, summary: summary,
                            id: block["id"] as? String, at: timestamp)
            default:
                break
            }
        }
    }

    private mutating func trackCounters(toolName: String, input: [String: Any]) {
        switch toolName {
        case "Bash":
            commandCount += 1 // REQ-CLA-23
        case "Edit", "Write", "NotebookEdit", "MultiEdit":
            if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
                touchedFiles.insert(path)
            }
        default:
            break
        }
    }

    private mutating func appendEvent(kind: TimelineEvent.Kind, summary: String, id: String?, at timestamp: Date) {
        lastActivity = summary
        timeline.append(TimelineEvent(
            id: id ?? UUID().uuidString,
            timestamp: timestamp,
            kind: kind,
            summary: summary
        ))
        if timeline.count > Self.timelineCap {
            timeline.removeFirst(timeline.count - Self.timelineCap)
        }
    }

    mutating func noteSubagentActivity(file: String, summary: String?, now: Date) {
        subagentFiles.insert(file)
        lastWriteAt = now
        let text = summary.map { "Subagent: \($0)" } ?? "Subagent running"
        lastActivity = text
        appendEvent(kind: .subagent, summary: text, id: nil, at: now)
    }

    // MARK: - Résumés en langage clair (07 · §3.4, sous-ensemble M1)

    static func summarizeToolUse(name: String, input: [String: Any]) -> String {
        func basename(_ key: String) -> String? {
            (input[key] as? String).map { (($0 as NSString).lastPathComponent) }
        }
        switch name {
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty {
                return truncate(description, 70)
            }
            if let command = input["command"] as? String {
                return truncate("Ran `\(command)`", 70)
            }
            return "Ran a command"
        case "Edit", "MultiEdit":
            return "Edited \(basename("file_path") ?? "a file")"
        case "Write":
            return "Wrote \(basename("file_path") ?? "a file")"
        case "Read":
            return "Read \(basename("file_path") ?? "a file")"
        case "Glob", "Grep":
            return "Searched files"
        case "WebFetch":
            if let url = input["url"] as? String, let host = URL(string: url)?.host() {
                return "Fetched \(host)"
            }
            return "Fetched a page"
        case "WebSearch":
            return "Searched the web"
        case "Task", "Agent":
            return "Launched a subagent"
        case "TodoWrite":
            return "Updated todos"
        case "AskUserQuestion":
            return "Asked a question"
        case "ExitPlanMode":
            return "Proposed a plan"
        default:
            return name
        }
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    static func parseTimestamp(_ string: String) -> Date? {
        (try? fractionalStyle.parse(string)) ?? (try? plainStyle.parse(string))
    }
}

/// Machine à états **fallback** (03 · REQ-CLA-31, 02 · §3.3) : sans hooks, `waiting`
/// n'est JAMAIS inféré (les transcripts ne marquent pas fiablement les permissions).
/// Un tool_use non apparié maintient `executing` (AC-08 : un Bash long reste executing) ;
/// le garde-fou de 30 min couvre les sessions mortes en plein outil (crash du terminal).
enum FallbackState {
    static func compute(
        hasPendingTool: Bool,
        lastEntryIsAssistant: Bool,
        lastStopReasonIsNull: Bool,
        secondsSinceLastWrite: TimeInterval
    ) -> SessionState {
        if hasPendingTool {
            return secondsSinceLastWrite < 1800 ? .executing : .idle
        }
        if lastEntryIsAssistant && lastStopReasonIsNull {
            return secondsSinceLastWrite < 10 ? .thinking : .idle
        }
        if !lastEntryIsAssistant && secondsSinceLastWrite < 10 {
            return .thinking // prompt soumis, le modèle démarre
        }
        return .idle
    }
}
