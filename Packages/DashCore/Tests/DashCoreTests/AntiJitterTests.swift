import DashCore
import Foundation
import Testing
import TestSupport

@Suite("Anti-sautillement du tri (07 · REQ-SES-05)")
@MainActor
struct AntiJitterTests {
    private func session(_ id: String, state: SessionState, lastEvent: TimeInterval, project: String = "p") -> Session {
        var s = Session(
            id: SessionID(agent: .claude, nativeID: id),
            state: state, title: id, projectPath: "/tmp/\(project)",
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        s.lastEventAt = Date(timeIntervalSince1970: lastEvent)
        return s
    }

    @Test("un reorder dû seulement à lastEventAt est coalescé (< 2 s)")
    func lastEventCoalesced() {
        let store = SessionStore()
        var now = Date(timeIntervalSince1970: 10_000)
        store.clockNow = { now }
        // Deux sessions executing, A plus récente que B → A avant B.
        store.replaceAll([
            session("A", state: .executing, lastEvent: 100),
            session("B", state: .executing, lastEvent: 90),
        ])
        #expect(store.groups.first?.sessions.map(\.id.nativeID) == ["A", "B"])

        // 1 s plus tard, B devient plus récente (lastEventAt only) : PAS de reorder immédiat.
        now = now.addingTimeInterval(1)
        store.replaceAll([
            session("A", state: .executing, lastEvent: 100),
            session("B", state: .executing, lastEvent: 200),
        ])
        #expect(store.groups.first?.sessions.map(\.id.nativeID) == ["A", "B"]) // ordre conservé

        // Au-delà de 2 s : le reorder s'applique.
        now = now.addingTimeInterval(2.5)
        #expect(store.groups.first?.sessions.map(\.id.nativeID) == ["B", "A"])
    }

    @Test("un changement de rang d'état réordonne immédiatement")
    func stateChangeImmediate() {
        let store = SessionStore()
        var now = Date(timeIntervalSince1970: 10_000)
        store.clockNow = { now }
        store.replaceAll([
            session("A", state: .executing, lastEvent: 100),
            session("B", state: .idle, lastEvent: 90),
        ])
        #expect(store.groups.first?.sessions.map(\.id.nativeID) == ["A", "B"])

        // 0,5 s plus tard, B passe waiting (rang 0 < executing) : reorder IMMÉDIAT malgré < 2 s.
        now = now.addingTimeInterval(0.5)
        store.replaceAll([
            session("A", state: .executing, lastEvent: 100),
            session("B", state: .waiting, lastEvent: 90),
        ])
        #expect(store.groups.first?.sessions.map(\.id.nativeID) == ["B", "A"])
    }

    @Test("l'apparition d'une session est immédiate")
    func appearanceImmediate() {
        let store = SessionStore()
        var now = Date(timeIntervalSince1970: 10_000)
        store.clockNow = { now }
        store.replaceAll([session("A", state: .executing, lastEvent: 100)])
        _ = store.groups
        now = now.addingTimeInterval(0.5)
        store.replaceAll([
            session("A", state: .executing, lastEvent: 100),
            session("C", state: .waiting, lastEvent: 110),
        ])
        let ids = store.groups.flatMap { $0.sessions.map(\.id.nativeID) }
        #expect(Set(ids) == ["A", "C"]) // C apparaît immédiatement
    }
}
