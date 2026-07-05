import DashCore
import Foundation
import Testing

/// Cursor marque tous ses composers `.live` à vie (pas de fin fiable dans `state.vscdb`) :
/// `displaySessions` ne doit exposer que les sessions Cursor actives (waiting/executing),
/// sinon l'historique de conversations idle encombre le panel et fausse le compteur.
@Suite("Filtre d'affichage Cursor (idle masqué)")
@MainActor
struct CursorDisplayFilterTests {
    private func cursor(_ id: String, state: SessionState) -> Session {
        Session(id: SessionID(agent: .cursor, nativeID: id), state: state,
                liveness: .live, title: id, startedAt: Date(timeIntervalSince1970: 1000))
    }

    private func claude(_ id: String, state: SessionState) -> Session {
        Session(id: SessionID(agent: .claude, nativeID: id), state: state,
                liveness: .live, title: id, startedAt: Date(timeIntervalSince1970: 1000))
    }

    @Test("une session Cursor idle n'est pas affichée, une active oui")
    func cursorIdleHidden() {
        let store = SessionStore()
        store.replaceAll([
            cursor("idle", state: .idle),
            cursor("exec", state: .executing),
            cursor("wait", state: .waiting),
        ])
        let ids = Set(store.displaySessions.map(\.id.nativeID))
        #expect(ids == ["exec", "wait"])
        #expect(store.liveCount == 2)
    }

    @Test("une session Claude idle live reste affichée (comportement inchangé)")
    func claudeIdleStillShown() {
        let store = SessionStore()
        store.replaceAll([claude("c-idle", state: .idle)])
        #expect(store.displaySessions.map(\.id.nativeID) == ["c-idle"])
    }
}
