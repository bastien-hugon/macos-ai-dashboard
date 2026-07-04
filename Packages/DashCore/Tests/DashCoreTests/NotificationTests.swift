import DashCore
import Foundation
import Testing

@Suite("NotificationComposer (12 · §3)")
struct NotificationComposerTests {
    private let session = SessionID(agent: .claude, nativeID: "s1")

    @Test("permission : throttle ≤ 1 post / session / 10 s")
    func permissionThrottle() {
        var composer = NotificationComposer()
        let first = composer.permissionRequest(session: session, projectName: "p", toolTitle: "Run", nowMonotonic: 100)
        let tooSoon = composer.permissionRequest(session: session, projectName: "p", toolTitle: "Run", nowMonotonic: 105)
        let later = composer.permissionRequest(session: session, projectName: "p", toolTitle: "Run", nowMonotonic: 111)
        #expect(first != nil)
        #expect(tooSoon == nil) // < 10 s
        #expect(later != nil)   // ≥ 10 s
        #expect(first?.categoryIdentifier == "PERMISSION_REQUEST")
        #expect(first?.identifier == "perm|s1") // identifiant stable → remplace
    }

    @Test("budget : au plus une alerte par (fenêtre, seuil, cycle) ; rearm après rollover")
    func budgetDedup() {
        var composer = NotificationComposer()
        let reset = Date(timeIntervalSince1970: 1_780_000_000)
        let first = composer.budgetAlert(kind: .fiveHour, threshold: 80, utilization: 85, resetsAt: reset)
        let dup = composer.budgetAlert(kind: .fiveHour, threshold: 80, utilization: 90, resetsAt: reset)
        #expect(first != nil)
        #expect(dup == nil)
        composer.rearmBudget(kind: .fiveHour)
        let afterRollover = composer.budgetAlert(kind: .fiveHour, threshold: 80, utilization: 85, resetsAt: reset.addingTimeInterval(18000))
        #expect(afterRollover != nil)
    }

    @Test("contenus : titres anglais, threadIdentifier par session")
    func contents() {
        var composer = NotificationComposer()
        let done = composer.taskComplete(session: session, projectName: "myproj")
        #expect(done.title == "Claude Code finished")
        #expect(done.subtitle == "myproj")
        #expect(done.threadIdentifier == "claude|s1")
        let test = composer.test()
        #expect(test.kind == .test)
        let stuck = composer.stuckSession(session: session, projectName: "p", seconds: 180)
        #expect(stuck.body.contains("3 min"))
    }
}
