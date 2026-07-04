import DashCore
import Foundation
import Testing
import TestSupport

@Suite("StateCache — persistance des stats journalières (REQ-USG-27)")
struct StateCacheTests {
    private func sample() -> [DailyUsage] {
        [
            DailyUsage(id: "2026-07-04|claude", date: Date(timeIntervalSince1970: 1_783_000_000),
                       agent: .claude, tokens: TokenTally(inputTokens: 24_600, outputTokens: 66, cacheReadTokens: 90_000),
                       costUSD: 1.23, sessionCount: 3),
            DailyUsage(id: "2026-07-03|claude", date: Date(timeIntervalSince1970: 1_782_900_000),
                       agent: .claude, tokens: TokenTally(inputTokens: 1000, outputTokens: 200), costUSD: 0.5, sessionCount: 1),
        ]
    }

    @Test("round-trip : save puis load restitue les stats")
    func roundTrip() throws {
        let paths = try SandboxHome.create()
        let cache = StateCache(paths: paths)
        cache.saveDaily(sample())
        let loaded = cache.loadDaily()
        #expect(loaded?.count == 2)
        #expect(loaded?.first?.tokens.inputTokens == 24_600)
        #expect(loaded?.first?.costUSD == 1.23)
        #expect(loaded?.first?.sessionCount == 3)
    }

    @Test("cache absent → nil")
    func missing() throws {
        let paths = try SandboxHome.create()
        #expect(StateCache(paths: paths).loadDaily() == nil)
    }

    @Test("cache périmé (au-delà de maxAge) → nil")
    func stale() throws {
        let paths = try SandboxHome.create()
        let cache = StateCache(paths: paths)
        cache.saveDaily(sample())
        // maxAge très court → immédiatement périmé.
        #expect(cache.loadDaily(maxAgeHours: 0) == nil)
        // maxAge normal → présent.
        #expect(cache.loadDaily(maxAgeHours: 24) != nil)
    }

    @Test("snapshot de sessions : round-trip, timeline/pid élagués")
    func sessionsSnapshot() throws {
        let paths = try SandboxHome.create()
        let cache = StateCache(paths: paths)
        var s = Session(id: SessionID(agent: .cursor, nativeID: "c1"), state: .executing,
                        title: "Fix bug", projectPath: "/tmp/proj", startedAt: Date(),
                        host: .ide("Cursor"), diff: DiffStats(added: 5, removed: 2), filesTouched: 1)
        s.timeline = [TimelineEvent(id: "t", timestamp: Date(), kind: .toolCall, summary: "Ran cmd")]
        s.pid = 4242
        cache.saveSessions([s])
        let loaded = try #require(cache.loadSessions())
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Fix bug")
        #expect(loaded.first?.host == .ide("Cursor"))
        #expect(loaded.first?.diff == DiffStats(added: 5, removed: 2))
        #expect(loaded.first?.timeline.isEmpty == true) // élagué
        #expect(loaded.first?.pid == nil)               // élagué (volatil)
    }
}
