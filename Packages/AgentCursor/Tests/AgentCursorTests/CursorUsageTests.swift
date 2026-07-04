import DashCore
import Foundation
import Testing
@testable import AgentCursor

@Suite("CursorUsagePoller — décodage usage-summary (04 · §3.3)")
struct CursorUsageDecodeTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func decode(_ json: String, measure: CursorUsageMeasure) throws -> UsageWindow {
        let snapshot = try CursorUsagePoller.decode(Data(json.utf8), account: "a", measure: measure, now: now)
        return try #require(snapshot.windows.first)
    }

    // Structure VÉRIFIÉE sur la réponse réelle (plan enterprise) : plan.*PercentUsed = %,
    // onDemand.used/limit = cents ($ réels), plan.used/limit = comptes d'unités (jamais des $).
    @Test("Spend : dollars depuis onDemand (cents), jamais depuis plan.used")
    func spend() throws {
        let window = try decode("""
        { "billingCycleEnd": "2026-07-31T00:00:00Z",
          "individualUsage": {
            "plan": { "used": 2000, "limit": 2000, "totalPercentUsed": 100, "autoPercentUsed": 100, "apiPercentUsed": 100 },
            "onDemand": { "used": 250725, "limit": null } } }
        """, measure: .spend)
        #expect(window.kind == .monthly)
        #expect(window.dollars?.used == 2507.25)      // onDemand cents → $, PAS plan.used/100
        #expect(window.dollars?.limit == .infinity)   // onDemand.limit null → illimité
        #expect(window.utilization == 100)            // pas de limite on-demand → % pondéré
        #expect(window.resetsAt != nil)
    }

    @Test("Weighted/Auto/API sélectionnent le bon pourcentage (plan.*PercentUsed)")
    func measures() throws {
        let json = """
        { "individualUsage": { "plan": {
          "totalPercentUsed": 33, "autoPercentUsed": 15, "apiPercentUsed": 40 } } }
        """
        #expect(try decode(json, measure: .weighted).utilization == 33)
        #expect(try decode(json, measure: .auto).utilization == 15)
        #expect(try decode(json, measure: .api).utilization == 40)
    }

    @Test("pas de dépense on-demand → aucun dollar affiché")
    func noSpend() throws {
        let window = try decode("""
        { "individualUsage": { "plan": { "totalPercentUsed": 12 } } }
        """, measure: .weighted)
        #expect(window.dollars == nil)
        #expect(window.utilization == 12)
    }

    @Test("billingCycleEnd accepté en ISO ou epoch ms (string)")
    func cycleDateFormats() {
        #expect(CursorUsagePoller.parseCycleDate("2026-07-31T00:00:00Z") != nil)
        #expect(CursorUsagePoller.parseCycleDate("1785000000000") != nil)
        #expect(CursorUsagePoller.parseCycleDate(NSNumber(value: 1_785_000_000_000)) != nil)
    }

    @Test("extraction du sub JWT (userId)")
    func jwtSubject() {
        // header.payload.signature ; payload = {"sub":"google-oauth2|user_abc"}
        let payload = Data(#"{"sub":"google-oauth2|user_abc"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let jwt = "aGVhZGVy.\(payload).c2ln"
        #expect(CursorUsagePoller.jwtSubject(jwt) == "google-oauth2|user_abc")
    }
}
