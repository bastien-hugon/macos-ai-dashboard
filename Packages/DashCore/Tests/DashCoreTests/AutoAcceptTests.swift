import DashCore
import Foundation
import Testing

/// Auto-accept opt-in par agent : SEULES les permissions sont auto-acceptées, et uniquement
/// pour l'agent dont le toggle est actif. Plans et questions passent toujours par l'humain.
@Suite("Auto-accept (gate + flush des prompts en file)")
@MainActor
struct AutoAcceptTests {
    private func prompt(agent: AgentKind, payload: PendingPromptPayload) -> PendingPrompt {
        PendingPrompt(
            sessionID: SessionID(agent: agent, nativeID: "s-\(agent.rawValue)"),
            receivedAt: Date(), expiresAt: Date().addingTimeInterval(500),
            payload: payload,
            capabilities: PromptCapabilities(canAlwaysAllow: false, canDenyWithFeedback: true, canAnswerInline: false, canApprovePlan: false, canHandInToTerminal: true),
            sessionLabel: "proj"
        )
    }

    private func permission(agent: AgentKind) -> PendingPrompt {
        prompt(agent: agent, payload: .permission(PermissionRequest(toolName: "Bash", displayTitle: "Run", cwd: "/tmp")))
    }

    @Test("gate : permission acceptée seulement pour l'agent dont le toggle est actif")
    func gatePerAgent() {
        #expect(AutoAcceptGate.shouldAutoAccept(permission(agent: .claude), claudeEnabled: true, cursorEnabled: false))
        #expect(!AutoAcceptGate.shouldAutoAccept(permission(agent: .claude), claudeEnabled: false, cursorEnabled: true))
        #expect(AutoAcceptGate.shouldAutoAccept(permission(agent: .cursor), claudeEnabled: false, cursorEnabled: true))
        #expect(!AutoAcceptGate.shouldAutoAccept(permission(agent: .cursor), claudeEnabled: true, cursorEnabled: false))
    }

    @Test("gate : plans et questions ne sont JAMAIS auto-acceptés")
    func gateNeverPlansOrQuestions() {
        let plan = prompt(agent: .claude, payload: .plan(PlanProposal(markdown: "# p", title: "Plan", viaPreToolUse: false)))
        let question = prompt(agent: .claude, payload: .question(QuestionPrompt(
            questions: [AgentQuestion(id: "q", header: nil, text: "q", options: [], multiSelect: false)],
            toolName: "AskUserQuestion", originalInputJSON: "{}", viaPreToolUse: false
        )))
        #expect(!AutoAcceptGate.shouldAutoAccept(plan, claudeEnabled: true, cursorEnabled: true))
        #expect(!AutoAcceptGate.shouldAutoAccept(question, claudeEnabled: true, cursorEnabled: true))
    }

    @Test("flush : bascule du toggle avec des prompts en file → permissions de l'agent résolues en allow")
    func flushPending() {
        let store = PromptStore()
        var decisions: [(SessionID, PromptDecision, DecisionSource)] = []
        store.onDecision = { decisions.append(($0, $1, $2)) }

        final class ReplyBox: @unchecked Sendable {
            var claudeReply: Data?
            var cursorReplied = false
        }
        let box = ReplyBox()
        let claudePerm = permission(agent: .claude)
        let cursorPerm = permission(agent: .cursor)
        let claudePlan = prompt(agent: .claude, payload: .plan(PlanProposal(markdown: "# p", title: "Plan", viaPreToolUse: false)))
        store.enqueue(claudePerm) { box.claudeReply = $0 }
        store.enqueue(cursorPerm) { _ in box.cursorReplied = true }
        store.enqueue(claudePlan) { _ in }

        // Toggle Claude seul → seule la permission Claude est résolue.
        store.autoAcceptPending(claude: true, cursor: false)
        #expect(box.claudeReply != nil) // décision encodée envoyée (allow)
        #expect(!box.cursorReplied)
        #expect(store.prompts.count == 2) // permission Cursor + plan Claude restent
        #expect(store.prompts.contains { $0.id == claudePlan.id }) // le plan n'est pas touché
        #expect(decisions.count == 1)
        if case .allow = decisions[0].1 {} else { Issue.record("décision attendue : allow") }
        #expect(decisions[0].2 == .auto)

        // Les deux toggles off → no-op.
        store.autoAcceptPending(claude: false, cursor: false)
        #expect(store.prompts.count == 2)
    }

    @Test("défauts produit : auto-accept OFF par défaut pour les deux agents")
    func defaultsOff() {
        let defaults = UserDefaults(suiteName: "autoaccept-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.autoAcceptClaude)
        #expect(!settings.autoAcceptCursor)
    }
}
