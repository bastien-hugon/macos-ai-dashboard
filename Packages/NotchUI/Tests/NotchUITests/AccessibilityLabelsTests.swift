import DashCore
import Foundation
import Testing
@testable import NotchUI

@Suite("AccessibilityLabels (REQ-NUI-57)")
struct AccessibilityLabelsTests {
    private func session(_ state: SessionState, live: Bool = true) -> Session {
        Session(id: SessionID(agent: .claude, nativeID: UUID().uuidString),
                state: state, liveness: live ? .live : .ended(.exited),
                title: "T", projectPath: "/tmp/p", startedAt: Date())
    }

    @Test("pill : agrège running et waiting")
    func pillLabel() {
        let label = AccessibilityLabels.pill(
            sessions: [session(.executing), session(.thinking), session(.waiting)],
            hasPrompt: true
        )
        #expect(label.contains("2 sessions running"))
        #expect(label.contains("1 waiting for input"))
        #expect(label.hasPrefix("AgentDash."))
    }

    @Test("pill : aucune session active")
    func pillEmpty() {
        #expect(AccessibilityLabels.pill(sessions: [], hasPrompt: false).contains("no active sessions"))
    }

    @Test("carte de session : agent, titre, état, tokens")
    func cardLabel() {
        var s = session(.executing)
        s.tokens = TokenTally(inputTokens: 24_600, outputTokens: 66)
        s.lastActivity = "Ran git status"
        let label = AccessibilityLabels.sessionCard(s)
        #expect(label.contains("Claude Code: T"))
        #expect(label.contains("running"))
        #expect(label.contains("Ran git status"))
        #expect(label.contains("24.6k input"))
    }

    @Test("jauge : titre, pourcentage, légende")
    func gaugeLabel() {
        let label = AccessibilityLabels.gauge(title: "5-hour", percentText: "57%", caption: "Resets in 2h")
        #expect(label == "5-hour: 57%, Resets in 2h")
    }

    @Test("annonce de prompt selon le type")
    func announcement() {
        let perm = PendingPrompt(
            sessionID: SessionID(agent: .claude, nativeID: "s"),
            receivedAt: Date(), expiresAt: Date(),
            payload: .permission(PermissionRequest(toolName: "Bash", displayTitle: "Run tests", cwd: "/p")),
            capabilities: PromptCapabilities(canAlwaysAllow: false, canDenyWithFeedback: true, canAnswerInline: false, canApprovePlan: false, canHandInToTerminal: true),
            sessionLabel: "myproj"
        )
        #expect(AccessibilityLabels.promptAnnouncement(perm) == "myproj needs permission: Run tests")
    }
}
