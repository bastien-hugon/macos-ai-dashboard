import AgentClaude
import DashCore
import Foundation

/// Orchestre le poller d'usage Claude et l'agrégateur de stats journalières (M3).
/// Boucle de poll à 180 s avec back-off sur échec, relecture Keychain sur 401 (une fois),
/// publication vers l'`UsageStore` sur MainActor. Anti-rafale du refresh manuel : 10 s.
actor ClaudeUsageController {
    private let poller: ClaudeUsagePoller
    private let dailyAggregator: DailyStatsAggregator
    private let store: UsageStore

    private var loopTask: Task<Void, Never>?
    private var lastManualRefresh: Date = .distantPast
    private var currentInterval: TimeInterval = 180

    init(paths: DashPaths, store: UsageStore) {
        self.poller = ClaudeUsagePoller(paths: paths)
        self.dailyAggregator = DailyStatsAggregator(paths: paths)
        self.store = store
    }

    func start() async {
        // Comptes + stats journalières en tâche de fond.
        do {
            let accounts = try await poller.discoverAccounts()
            await store.setAccounts(accounts)
            DashLog.file("usage: comptes découverts = \(accounts.count) (\(accounts.first?.label ?? "?"))", category: "usage")
        } catch {
            DashLog.file("usage: discoverAccounts ÉCHEC = \(error)", category: "usage")
        }
        await refreshDaily()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let interval = await self?.currentInterval ?? 180
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Refresh manuel (bouton) — anti-rafale 10 s (REQ-USG-31).
    func refreshNow() async {
        let now = Date()
        guard now.timeIntervalSince(lastManualRefresh) >= 10 else {
            await MainActor.run { _ = self.store } // no-op : refresh trop rapproché
            return
        }
        lastManualRefresh = now
        await pollOnce()
    }

    private func pollOnce() async {
        do {
            let snapshot = try await poller.fetchUsage()
            currentInterval = 180 // succès → réinitialise le back-off
            let summary = snapshot.windows.map { "\($0.kind.rawValue)=\(Int($0.utilization))%" }.joined(separator: " ")
            DashLog.file("usage: poll OK \(summary)", category: "usage")
            await store.apply(snapshot)
        } catch let error as UsageError {
            if case .rateLimited = error {
                currentInterval = min(currentInterval * 2, 900) // back-off exponentiel plafonné
            }
            DashLog.file("usage: poll ÉCHEC \(error)", category: "usage")
            await store.markFailure(.claude, error)
        } catch {
            DashLog.file("usage: poll ÉCHEC réseau \(error.localizedDescription)", category: "usage")
            await store.markFailure(.claude, .network(error.localizedDescription))
        }
    }

    private func refreshDaily() async {
        let daily = await dailyAggregator.aggregate()
        await store.setDaily(daily)
    }
}
