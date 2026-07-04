import AgentCursor
import DashCore
import Foundation

/// Orchestre le poller d'usage mensuel Cursor (M7) : poll 300 s, publication vers l'UsageStore.
actor CursorUsageController {
    private let poller: CursorUsagePoller
    private let store: UsageStore
    private var loopTask: Task<Void, Never>?

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
    }
}
