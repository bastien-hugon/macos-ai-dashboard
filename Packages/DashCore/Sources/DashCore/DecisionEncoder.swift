import Foundation

/// Encode une décision utilisateur dans le format JSON exact attendu par l'agent
/// (08 · §3.3, formats VÉRIFIÉS dans la doc). Le corps est écrit tel quel sur le stdout
/// du hook. `nil` = corps vide (« pas d'avis » → dialogue natif du terminal).
public enum DecisionEncoder {
    public static func encode(_ decision: PromptDecision, for prompt: PendingPrompt) -> Data? {
        switch prompt.sessionID.agent {
        case .claude: encodeClaude(decision, for: prompt)
        case .cursor: encodeCursor(decision, for: prompt)
        }
    }

    // MARK: - Claude Code

    private static func encodeClaude(_ decision: PromptDecision, for prompt: PendingPrompt) -> Data? {
        switch decision {
        case .allow:
            return permissionRequestOutput(["behavior": "allow"])

        case .alwaysAllow(let suggestion):
            var inner: [String: Any] = ["behavior": "allow"]
            if let encoded = try? JSONEncoder().encode(suggestion),
               let object = try? JSONSerialization.jsonObject(with: encoded) {
                inner["updatedPermissions"] = [object]
            }
            return permissionRequestOutput(inner)

        case .deny(let feedback):
            var inner: [String: Any] = ["behavior": "deny"]
            if let feedback, !feedback.isEmpty { inner["message"] = feedback }
            return permissionRequestOutput(inner)

        case .approvePlan(let switchToAcceptEdits):
            if case .plan(let plan) = prompt.payload, plan.viaPreToolUse {
                return preToolUseOutput(decision: "allow", extra: [:])
            }
            var inner: [String: Any] = ["behavior": "allow"]
            if switchToAcceptEdits {
                inner["updatedPermissions"] = [[
                    "type": "setMode", "mode": "acceptEdits", "destination": "session",
                ]]
            }
            return permissionRequestOutput(inner)

        case .rejectPlan(let feedback):
            if case .plan(let plan) = prompt.payload, plan.viaPreToolUse {
                return preToolUseOutput(decision: "deny", extra: ["permissionDecisionReason": feedback])
            }
            return permissionRequestOutput(["behavior": "deny", "message": feedback])

        case .answers(let map):
            // Questions : allow + updatedInput = { …input original…, answers } (REQ-CLA-44).
            guard case .question(let question) = prompt.payload else { return nil }
            var updatedInput = (try? JSONSerialization.jsonObject(
                with: Data(question.originalInputJSON.utf8)
            )) as? [String: Any] ?? [:]
            updatedInput["answers"] = map
            return preToolUseOutput(decision: "allow", extra: ["updatedInput": updatedInput])

        case .handInToTerminal:
            return nil // corps vide
        }
    }

    private static func permissionRequestOutput(_ decision: [String: Any]) -> Data? {
        serialize([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ])
    }

    private static func preToolUseOutput(decision: String, extra: [String: Any]) -> Data? {
        var specific: [String: Any] = [
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
        ]
        specific.merge(extra) { _, new in new }
        return serialize(["hookSpecificOutput": specific])
    }

    // MARK: - Cursor

    private static func encodeCursor(_ decision: PromptDecision, for prompt: PendingPrompt) -> Data? {
        switch decision {
        case .allow, .alwaysAllow, .approvePlan:
            return serialize(["permission": "allow"])
        case .deny(let feedback), .rejectPlan(let feedback as String?):
            var object: [String: Any] = ["permission": "deny"]
            if let feedback, !feedback.isEmpty {
                object["user_message"] = feedback
                object["agent_message"] = feedback // double champ tant que l'hypothèse n'est pas tranchée
            }
            return serialize(object)
        case .answers, .handInToTerminal:
            return serialize(["permission": "ask"]) // Cursor : questions non actionnables
        }
    }

    // MARK: -

    private static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
