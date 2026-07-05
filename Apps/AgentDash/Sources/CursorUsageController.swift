import AgentCursor
import DashCore
import Foundation

/// Orchestre le poller d'usage mensuel Cursor (M7) : poll 300 s, publication vers l'UsageStore.
actor CursorUsageController {
    private let poller: CursorUsagePoller
    private let store: UsageStore
    private var loopTask: Task<Void, Never>?
    /// Dépense team (cycle) + id numérique de l'user, rafraîchis à chaque poll (échec toléré).
    private var teamSpend: CursorUsagePoller.TeamSpend?

    init(paths: DashPaths, store: UsageStore, measure: @escaping @Sendable () -> CursorUsageMeasure) {
        self.poller = CursorUsagePoller(paths: paths, measure: measure)
        self.store = store
    }

    func start() async {
        if let accounts = try? await poller.discoverAccounts() {
            await store.addAccounts(accounts)
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refreshNow() async { await pollOnce() }

    private func pollOnce() async {
        do {
            let snapshot = try await poller.fetchUsage()
            DashLog.file("usage: Cursor OK monthly=\(Int(snapshot.windows.first?.utilization ?? 0))%", category: "usage")
            await store.apply(snapshot)
        } catch let error as UsageError {
            DashLog.file("usage: Cursor ÉCHEC \(error)", category: "usage")
            await store.markFailure(.cursor, error)
        } catch {
            await store.markFailure(.cursor, .network(error.localizedDescription))
        }
        // Dépense team (cycle) + résolution de l'userId — échec non bloquant, valeur conservée.
        if let spend = try? await poller.fetchTeamSpend() {
            teamSpend = spend
        }

        // Dépense + tokens du jour (ligne inline) — échec non bloquant.
        // Filtre défensif sur l'userId résolu pour ne refléter QUE l'utilisateur courant.
        do {
            let today = try await poller.fetchTodayEvents(userId: teamSpend?.myUserId)
            let teamCost = teamSpend?.cycleCostUSD
            DashLog.file(
                "usage: Cursor today $\(String(format: "%.2f", today.costUSD)) \(today.tokens) tokens"
                    + (teamCost.map { " (team cycle $\(String(format: "%.2f", $0)))" } ?? ""),
                category: "usage")
            await store.setToday(.cursor, UsageStore.TodayUsage(
                tokens: today.tokens, costUSD: today.costUSD, teamCostUSD: teamCost))
        } catch {
            DashLog.file("usage: Cursor today ÉCHEC \(error)", category: "usage")
        }
    }
}
