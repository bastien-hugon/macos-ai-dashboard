import DashCore
import Foundation

/// Construit la timeline d'une session Cursor depuis `composerData` + `bubbleId`
/// (research cursor §2.4/2.5) : ordre des bulles via `fullConversationHeadersOnly`, puis
/// lecture des dernières bulles pour extraire les tool calls (`toolFormerData`). Lecture
/// bornée (dernières N bulles) — jamais tout l'historique.
enum CursorTimelineReader {
    struct Detail {
        var timeline: [TimelineEvent]
        var subagentCount: Int
        var lastActivity: String?
    }

    static let maxBubbles = 14

    static func read(reader: SQLiteReader, composerId: String) -> Detail? {
        guard let data = reader.diskKVValue(key: "composerData:\(composerId)"),
              let composer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let headers = composer["fullConversationHeadersOnly"] as? [[String: Any]] ?? []
        let subagentCount = (composer["subagentComposerIds"] as? [Any])?.count
            ?? (composer["subComposerIds"] as? [Any])?.count ?? 0

        // Dernières bulles (ordre chronologique), lecture bornée.
        let recent = headers.suffix(maxBubbles)
        var events: [TimelineEvent] = []
        var lastActivity: String?
        for (index, header) in recent.enumerated() {
            guard let bubbleId = header["bubbleId"] as? String else { continue }
            guard let bubbleData = reader.diskKVValue(key: "bubbleId:\(composerId):\(bubbleId)"),
                  let bubble = try? JSONSerialization.jsonObject(with: bubbleData) as? [String: Any] else { continue }
            let type = (bubble["type"] as? NSNumber)?.intValue ?? 0 // 1=user, 2=assistant
            if let tool = bubble["toolFormerData"] as? [String: Any],
               let name = tool["name"] as? String {
                let summary = summarize(toolName: name, params: tool["params"] as? String,
                                        status: tool["status"] as? String)
                events.append(TimelineEvent(
                    id: bubbleId, timestamp: Date(), kind: .toolCall, summary: summary))
                lastActivity = summary
            } else if type == 1, let text = (bubble["text"] as? String), !text.isEmpty {
                events.append(TimelineEvent(
                    id: bubbleId, timestamp: Date(), kind: .prompt,
                    summary: truncate("Prompt: " + text, 80)))
            } else if type == 2, let text = (bubble["text"] as? String), !text.isEmpty, index == recent.count - 1 {
                lastActivity = truncate(text, 80)
            }
        }
        return Detail(timeline: events, subagentCount: subagentCount, lastActivity: lastActivity)
    }

    /// Traduit les noms d'outils internes Cursor en langage clair (research §2.5).
    static func summarize(toolName: String, params: String?, status: String?) -> String {
        let running = status == "loading" ? " (running)" : ""
        switch toolName {
        case "run_terminal_command_v2", "run_terminal_command":
            return "Ran a command" + running
        case "edit_file_v2", "edit_file", "apply_diff":
            return "Edited \(fileFrom(params) ?? "a file")" + running
        case "read_file_v2", "read_file":
            return "Read \(fileFrom(params) ?? "a file")" + running
        case "delete_file":
            return "Deleted \(fileFrom(params) ?? "a file")"
        case "ripgrep_raw_search", "grep_search", "semantic_search_full", "glob_file_search":
            return "Searched files" + running
        case "read_lints":
            return "Checked lints"
        case "todo_write":
            return "Updated todos"
        case "ask_question":
            return "Asked a question"
        case "create_plan":
            return "Proposed a plan"
        case "task_v2":
            return "Launched a subagent" + running
        default:
            if toolName.hasPrefix("mcp") { return "Ran an MCP tool" + running }
            return toolName + running
        }
    }

    private static func fileFrom(_ params: String?) -> String? {
        guard let params, let data = params.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let path = object["target_file"] as? String
            ?? object["path"] as? String
            ?? object["relative_workspace_path"] as? String
        return path.map { ($0 as NSString).lastPathComponent }
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
    }
}
