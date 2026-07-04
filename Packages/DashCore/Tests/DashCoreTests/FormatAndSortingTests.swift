import DashCore
import Foundation
import Testing
import TestSupport

@Suite("DashFormat (07 · REQ-SES-22/27)")
struct DashFormatTests {
    @Test("format des tokens : paliers et arrondis")
    func tokenFormat() {
        #expect(DashFormat.tokens(0) == "0")
        #expect(DashFormat.tokens(66) == "66")
        #expect(DashFormat.tokens(999) == "999")
        #expect(DashFormat.tokens(24_600) == "24.6k")
        #expect(DashFormat.tokens(24_000) == "24k")
        #expect(DashFormat.tokens(24_649) == "24.6k")
        #expect(DashFormat.tokens(24_650) == "24.7k")
        #expect(DashFormat.tokens(245_000) == "245k")
        #expect(DashFormat.tokens(1_200_000) == "1.2M")
        #expect(DashFormat.tokens(2_000_000) == "2M")
    }

    @Test("chip tokens : input seul / output")
    func tokenChip() {
        let tally = TokenTally(inputTokens: 24_600, outputTokens: 66, cacheReadTokens: 90_000, cacheCreationTokens: 0)
        #expect(DashFormat.tokenChip(tally) == "24.6k / 66") // caches exclus du chip (REQ-SES-21)
    }

    @Test("temps écoulé : 42s, 7m, 1h 24m, 2d 3h")
    func elapsed() {
        #expect(DashFormat.elapsed(42) == "42s")
        #expect(DashFormat.elapsed(7 * 60 + 30) == "7m")
        #expect(DashFormat.elapsed(3600 + 24 * 60) == "1h 24m")
        #expect(DashFormat.elapsed(2 * 86_400 + 3 * 3600 + 60) == "2d 3h")
    }
}

@Suite("SessionStore — tri et groupes (07 · REQ-SES-02..04)")
@MainActor
struct SessionSortingTests {
    @Test("tri intra-groupe : waiting < executing < thinking < idle < ended")
    func intraGroupRank() {
        let waiting = SessionFixtures.make(state: .waiting)
        let executing = SessionFixtures.make(state: .executing)
        let ended = SessionFixtures.make(state: .ended, liveness: .ended(.exited))
        let sorted = [ended, executing, waiting].sorted(by: SessionStore.intraGroupOrder)
        #expect(sorted.map(\.state) == [.waiting, .executing, .ended])
    }

    @Test("groupes : projet avec waiting en premier, Other en dernier")
    func groupOrder() {
        let store = SessionStore()
        var other = SessionFixtures.make(state: .executing)
        other.projectPath = nil
        store.replaceAll([
            SessionFixtures.make(state: .idle, project: "alpha"),
            SessionFixtures.make(state: .waiting, project: "zeta"),
            other,
        ])
        let groups = store.groups
        #expect(groups.count == 3)
        #expect(groups.first?.name == "zeta")   // contient la session waiting
        #expect(groups.last?.name == "Other")   // groupe terminal
    }

    @Test("GC d'affichage : session terminée depuis plus de 24 h masquée")
    func displayGC() {
        let store = SessionStore()
        var stale = SessionFixtures.make(state: .ended, liveness: .ended(.exited))
        stale.lastEventAt = Date(timeIntervalSinceNow: -30 * 3600)
        let live = SessionFixtures.make(state: .executing)
        store.replaceAll([stale, live])
        #expect(store.displaySessions.count == 1)
        #expect(store.displaySessions.first?.id == live.id)
    }
}
