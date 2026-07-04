import DashCore
import Foundation
import Testing
import TestSupport

@Suite("Actions de session (07 · REQ-SES-37..41)")
@MainActor
struct SessionActionsTests {
    @Test("dismiss masque la session de l'affichage")
    func dismiss() {
        let store = SessionStore()
        let s = SessionFixtures.make(state: .idle)
        store.replaceAll([s])
        #expect(store.displaySessions.count == 1)
        store.dismiss(s.id)
        #expect(store.displaySessions.isEmpty)
    }

    @Test("markEnded : passe la session en .ended(.killed)")
    func markEnded() {
        let store = SessionStore()
        let s = SessionFixtures.make(state: .executing)
        store.replaceAll([s])
        store.markEnded(s.id, reason: .killed)
        let updated = store.session(s.id)
        #expect(updated?.state == .ended)
        if case .ended(.killed) = updated?.liveness {} else { Issue.record("attendu .ended(.killed)") }
    }
}

@Suite("SessionMarkdown (07 · REQ-SES-40)")
struct SessionMarkdownTests {
    @Test("rend l'entête, les métriques et la timeline")
    func render() {
        var s = Session(
            id: SessionID(agent: .claude, nativeID: "s1"),
            state: .executing, title: "Fix the bug",
            projectPath: "/tmp/proj", startedAt: Date(),
            tokens: TokenTally(inputTokens: 24_600, outputTokens: 66),
            diff: DiffStats(added: 12, removed: 3), filesTouched: 2, commandCount: 1,
            gitBranch: "main", model: "claude-fable-5"
        )
        s.timeline = [TimelineEvent(id: "1", timestamp: Date(), kind: .toolCall, summary: "Ran `git status`")]
        let md = SessionMarkdown.render(s)
        #expect(md.contains("# Fix the bug"))
        #expect(md.contains("**Agent**: Claude Code"))
        #expect(md.contains("**Branch**: main"))
        #expect(md.contains("24.6k / 66"))
        #expect(md.contains("+12 −3"))
        #expect(md.contains("## Timeline"))
        #expect(md.contains("Ran `git status`"))
    }
}
