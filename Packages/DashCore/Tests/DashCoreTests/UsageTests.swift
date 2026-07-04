import DashCore
import Foundation
import Testing
import TestSupport

@Suite("Couleur de jauge & hystérésis (09 · REQ-USG-15)")
struct GaugeColorTests {
    @Test("seuils exacts sur le consommé")
    func thresholds() {
        #expect(gaugeColor(consumed: 0, previous: nil) == .green)
        #expect(gaugeColor(consumed: 69.9, previous: nil) == .green)
        #expect(gaugeColor(consumed: 70, previous: nil) == .yellow)
        #expect(gaugeColor(consumed: 89.9, previous: nil) == .yellow)
        #expect(gaugeColor(consumed: 90, previous: nil) == .red)
    }

    @Test("hystérésis en redescente (−2 points)")
    func hysteresis() {
        // rouge → jaune seulement sous 88
        #expect(gaugeColor(consumed: 89, previous: .red) == .red)
        #expect(gaugeColor(consumed: 87, previous: .red) == .yellow)
        // jaune → vert seulement sous 68
        #expect(gaugeColor(consumed: 69, previous: .yellow) == .yellow)
        #expect(gaugeColor(consumed: 67, previous: .yellow) == .green)
    }
}

@Suite("Formats d'usage (09 · REQ-USG-08/09/16)")
struct UsageFormatTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test("countdown 5h : Xh Ym / Xm / <1m")
    func countdown() {
        #expect(UsageFormat.resetCountdown(from: now, to: now.addingTimeInterval(2 * 3600 + 14 * 60)) == "Resets in 2h 14m")
        #expect(UsageFormat.resetCountdown(from: now, to: now.addingTimeInterval(37 * 60)) == "Resets in 37m")
        #expect(UsageFormat.resetCountdown(from: now, to: now.addingTimeInterval(30)) == "Resets in <1m")
    }

    @Test("percentText : consommé vs restant")
    func percentText() {
        #expect(UsageFormat.percentText(consumed: 33, countdownFrom100: false) == "33%")
        #expect(UsageFormat.percentText(consumed: 33, countdownFrom100: true) == "67% left")
        #expect(UsageFormat.percentText(consumed: 150, countdownFrom100: false) == "100%") // clamp
    }
}

@Suite("UsageStore (09 · REQ-USG-17/18/19/22)")
@MainActor
struct UsageStoreTests {
    private func snapshot(_ util: Double, kind: UsageWindowKind = .fiveHour, resetsAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(agent: .claude, account: "a",
                      windows: [UsageWindow(kind: kind, utilization: util, resetsAt: resetsAt, fetchedAt: Date())],
                      fetchedAt: Date())
    }

    @Test("jamais de valeur → jauge --")
    func neverFetched() {
        let store = UsageStore()
        let gauge = store.gauge(for: .fiveHour)
        #expect(gauge?.fillFraction == nil)
        #expect(gauge?.percentText == "--")
    }

    @Test("clamp du remplissage à [0,100]")
    func clamp() {
        let store = UsageStore()
        store.apply(snapshot(130))
        #expect(store.gauge(for: .fiveHour)?.fillFraction == 1.0)
    }

    @Test("échec → rétention de la dernière valeur, marquée stale, jamais effacée")
    func retention() {
        let store = UsageStore()
        store.apply(snapshot(42))
        store.markFailure(.claude, .network("offline"))
        let gauge = store.gauge(for: .fiveHour)
        #expect(gauge?.fillFraction == 0.42) // valeur retenue
        #expect(gauge?.isStale == true)
        #expect(gauge?.percentText != "--")
    }

    @Test("rollover : à l'échéance, la fenêtre repasse à 0 %")
    func rollover() {
        let store = UsageStore()
        let past = Date(timeIntervalSinceNow: -60)
        store.apply(snapshot(95, resetsAt: past))
        store.rolloverIfNeeded(now: Date())
        #expect(store.gauge(for: .fiveHour)?.fillFraction == 0)
    }
}

@Suite("BudgetAlertEvaluator (09 · REQ-USG-38/39)")
struct BudgetAlertTests {
    @Test("une seule alerte par (fenêtre, seuil, cycle)")
    func dedup() {
        var evaluator = BudgetAlertEvaluator()
        let reset = Date(timeIntervalSince1970: 1_780_000_000)
        let first = evaluator.evaluate(kind: .fiveHour, utilization: 85, threshold: 80, resetsAt: reset)
        let second = evaluator.evaluate(kind: .fiveHour, utilization: 92, threshold: 80, resetsAt: reset)
        #expect(first != nil)
        #expect(second == nil) // même cycle → pas de doublon
    }

    @Test("sous le seuil → aucune alerte")
    func belowThreshold() {
        var evaluator = BudgetAlertEvaluator()
        #expect(evaluator.evaluate(kind: .fiveHour, utilization: 50, threshold: 80, resetsAt: nil) == nil)
    }

    @Test("rollover (nouveau cycle) → l'alerte se réarme")
    func rearmOnNewCycle() {
        var evaluator = BudgetAlertEvaluator()
        let cycle1 = Date(timeIntervalSince1970: 1_780_000_000)
        let cycle2 = Date(timeIntervalSince1970: 1_790_000_000)
        _ = evaluator.evaluate(kind: .fiveHour, utilization: 85, threshold: 80, resetsAt: cycle1)
        evaluator.rearm(kind: .fiveHour)
        let afterRollover = evaluator.evaluate(kind: .fiveHour, utilization: 85, threshold: 80, resetsAt: cycle2)
        #expect(afterRollover != nil)
    }
}
