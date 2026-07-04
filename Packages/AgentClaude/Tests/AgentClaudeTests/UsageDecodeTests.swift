import DashCore
import Foundation
import Testing
@testable import AgentClaude

@Suite("ClaudeUsagePoller — décodage de l'endpoint (09 · REQ-USG-02)")
struct UsageDecodeTests {
    private func decode(_ json: String) throws -> UsageSnapshot {
        let poller = ClaudeUsagePoller(paths: DashPaths(home: URL(fileURLWithPath: "/tmp")))
        return try poller.decode(Data(json.utf8), account: "test")
    }

    @Test("réponse nominale : 4 fenêtres, utilization + resets_at")
    func nominal() throws {
        let snapshot = try decode("""
        {
          "five_hour":  { "utilization": 33.0, "resets_at": "2026-07-04T07:00:00.528743+00:00" },
          "seven_day":  { "utilization": 13.0, "resets_at": "2026-07-10T00:59:59.951713+00:00" },
          "seven_day_opus": null,
          "seven_day_sonnet": { "utilization": 1.0, "resets_at": "2026-07-09T03:00:00.951719+00:00" }
        }
        """)
        let byKind = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.kind, $0) })
        #expect(byKind[.fiveHour]?.utilization == 33.0)
        #expect(byKind[.fiveHour]?.resetsAt != nil)
        #expect(byKind[.sevenDay]?.utilization == 13.0)
        #expect(byKind[.sevenDaySonnet]?.utilization == 1.0)
        #expect(byKind[.sevenDayOpus] == nil) // null → fenêtre absente (décodage tolérant)
    }

    @Test("réponse sans aucune fenêtre → erreur de décodage")
    func empty() {
        #expect(throws: UsageError.self) {
            _ = try decode(#"{"seven_day_opus": null}"#)
        }
    }

    @Test("champ utilization manquant → fenêtre ignorée, pas de crash")
    func tolerant() throws {
        let snapshot = try decode("""
        { "five_hour": { "resets_at": "2026-07-04T07:00:00Z" },
          "seven_day": { "utilization": 50.0, "resets_at": "2026-07-10T00:00:00Z" } }
        """)
        #expect(snapshot.windows.count == 1) // five_hour sans utilization ignorée
        #expect(snapshot.windows.first?.kind == .sevenDay)
    }
}
