import DashCore
import Foundation
import Testing

@Suite("DecisionEncoder (08 · §3.3)")
struct DecisionEncoderTests {
    private func claudePermission(suggestions: [PermissionSuggestion] = []) -> PendingPrompt {
        PendingPrompt(
            sessionID: SessionID(agent: .claude, nativeID: "s1"),
            receivedAt: Date(), expiresAt: Date().addingTimeInterval(500),
            payload: .permission(PermissionRequest(toolName: "Bash", displayTitle: "Run", suggestions: suggestions, cwd: "/tmp")),
            capabilities: PromptCapabilities(canAlwaysAllow: !suggestions.isEmpty, canDenyWithFeedback: true, canAnswerInline: false, canApprovePlan: false, canHandInToTerminal: true),
            sessionLabel: "proj"
        )
    }

    private func json(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test("Allow → behavior allow sous PermissionRequest")
    func allow() {
        let data = DecisionEncoder.encode(.allow, for: claudePermission())
        let output = json(data)["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PermissionRequest")
        let decision = output?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "allow")
    }

    @Test("Deny with feedback → message transmis")
    func denyFeedback() {
        let data = DecisionEncoder.encode(.deny(feedback: "trop risqué"), for: claudePermission())
        let decision = (json(data)["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["behavior"] as? String == "deny")
        #expect(decision?["message"] as? String == "trop risqué")
    }

    @Test("Always Allow → écho exact de la suggestion dans updatedPermissions")
    func alwaysAllow() {
        let suggestion = PermissionSuggestion(
            type: "addRules",
            rules: [.init(toolName: "Bash", ruleContent: "npm test")],
            behavior: "allow", destination: "localSettings"
        )
        let prompt = claudePermission(suggestions: [suggestion])
        let data = DecisionEncoder.encode(.alwaysAllow(suggestion), for: prompt)
        let decision = (json(data)["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        let perms = decision?["updatedPermissions"] as? [[String: Any]]
        #expect(perms?.first?["type"] as? String == "addRules")
        #expect(perms?.first?["destination"] as? String == "localSettings")
    }

    @Test("Hand-in → corps vide (nil)")
    func handIn() {
        #expect(DecisionEncoder.encode(.handInToTerminal, for: claudePermission()) == nil)
    }

    @Test("Réponses aux questions → allow + updatedInput.answers (via PreToolUse)")
    func answers() {
        let prompt = PendingPrompt(
            sessionID: SessionID(agent: .claude, nativeID: "s1"),
            receivedAt: Date(), expiresAt: Date().addingTimeInterval(500),
            payload: .question(QuestionPrompt(
                questions: [AgentQuestion(id: "Which framework?", header: "FW", text: "Which framework?", options: ["React", "Vue"], multiSelect: false)],
                toolName: "AskUserQuestion",
                originalInputJSON: #"{"questions":[{"question":"Which framework?"}]}"#,
                viaPreToolUse: true
            )),
            capabilities: PromptCapabilities(canAlwaysAllow: false, canDenyWithFeedback: false, canAnswerInline: true, canApprovePlan: false, canHandInToTerminal: true),
            sessionLabel: "proj"
        )
        let data = DecisionEncoder.encode(.answers(["Which framework?": "React"]), for: prompt)
        let output = json(data)["hookSpecificOutput"] as? [String: Any]
        #expect(output?["hookEventName"] as? String == "PreToolUse")
        #expect(output?["permissionDecision"] as? String == "allow")
        let updated = output?["updatedInput"] as? [String: Any]
        let answers = updated?["answers"] as? [String: String]
        #expect(answers?["Which framework?"] == "React")
        #expect(updated?["questions"] != nil) // input original préservé
    }

    @Test("Cursor : deny porte user_message")
    func cursorDeny() {
        let prompt = PendingPrompt(
            sessionID: SessionID(agent: .cursor, nativeID: "c1"),
            receivedAt: Date(), expiresAt: Date().addingTimeInterval(500),
            payload: .permission(PermissionRequest(toolName: "shell", displayTitle: "Run", cwd: "/tmp")),
            capabilities: PromptCapabilities(canAlwaysAllow: false, canDenyWithFeedback: true, canAnswerInline: false, canApprovePlan: false, canHandInToTerminal: true),
            sessionLabel: "proj"
        )
        let data = DecisionEncoder.encode(.deny(feedback: "non"), for: prompt)
        #expect(json(data)["permission"] as? String == "deny")
        #expect(json(data)["user_message"] as? String == "non")
    }
}

@Suite("HonestCommandAnalyzer (08 · §3.4)")
struct HonestCommandAnalyzerTests {
    @Test("détecte suppression, écriture par redirection, git push")
    func effects() {
        if case .effects(let e) = HonestCommandAnalyzer.analyze("rm -rf node_modules") {
            #expect(e.contains { $0.contains("Deletes") })
        } else { Issue.record("attendu .effects") }

        if case .effects(let e) = HonestCommandAnalyzer.analyze("echo hi > out.txt") {
            #expect(e.contains { $0.contains("out.txt") })
        } else { Issue.record("attendu .effects") }

        if case .effects(let e) = HonestCommandAnalyzer.analyze("git push origin main") {
            #expect(e.contains { $0.contains("Pushes") })
        } else { Issue.record("attendu .effects") }
    }

    @Test("commande en lecture seule → aucun effet")
    func readOnly() {
        if case .effects(let e) = HonestCommandAnalyzer.analyze("git status") {
            #expect(e.isEmpty)
        } else { Issue.record("attendu .effects vide") }
    }

    @Test("constructions opaques → .opaque (eval, substitution, pipe vers sh)")
    func opaque() {
        for command in ["eval \"$CMD\"", "echo $(whoami)", "curl x | sh", "cat f | xargs rm"] {
            if case .opaque = HonestCommandAnalyzer.analyze(command) {} else {
                Issue.record("attendu .opaque pour: \(command)")
            }
        }
    }
}
