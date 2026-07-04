import DashCore
import Foundation
import Testing

@Suite("SettingsStore — persistance & défauts")
@MainActor
struct SettingsStoreTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "agentdash.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("défauts produit (calibrage 3 juil.) : noir opaque, hooks/usage on")
    func defaults() {
        let s = SettingsStore(defaults: freshDefaults())
        #expect(s.glassOpacity == 1.0)
        #expect(s.frostedRim == false)
        #expect(s.claudeHooksEnabled)
        #expect(s.claudeUsageEnabled)
        #expect(s.promptHandling == .both)
        #expect(s.budgetThreshold5h == 80)
    }

    @Test("une valeur écrite est relue après recréation du store")
    func persistence() {
        let defaults = freshDefaults()
        let s1 = SettingsStore(defaults: defaults)
        s1.glassOpacity = 0.4
        s1.density = .colossal
        s1.notifyBudget = false
        let s2 = SettingsStore(defaults: defaults)
        #expect(s2.glassOpacity == 0.4)
        #expect(s2.density == .colossal)
        #expect(s2.notifyBudget == false)
    }
}

@Suite("DoctorStore — statut global")
@MainActor
struct DoctorStoreTests {
    @Test("agrégation : failure > warning > checking > ok")
    func overall() {
        let store = DoctorStore()
        store.setChecks([
            DoctorCheck(id: "a", title: "A", status: .ok, detail: ""),
            DoctorCheck(id: "b", title: "B", status: .warning, detail: ""),
        ])
        #expect(store.overall == .warning)
        store.update("b", status: .failure, detail: "")
        #expect(store.overall == .failure)
        store.update("b", status: .ok, detail: "")
        #expect(store.overall == .ok)
    }
}

@Suite("FastActionStore — CRUD & persistance")
@MainActor
struct FastActionStoreTests {
    @Test("upsert, run record, remove")
    func crud() {
        let defaults = UserDefaults(suiteName: "agentdash.fa.\(UUID().uuidString)")!
        let store = FastActionStore(defaults: defaults)
        let action = FastAction(title: "Build", command: "swift build")
        store.upsert(action)
        #expect(store.actions.count == 1)
        store.recordRun(action.id, exitCode: 0)
        #expect(store.actions.first?.lastExitCode == 0)
        // persistance
        let reloaded = FastActionStore(defaults: defaults)
        #expect(reloaded.actions.count == 1)
        reloaded.remove(action.id)
        #expect(reloaded.actions.isEmpty)
    }
}
