import DashCore
import Foundation

/// Ingesteur des sessions Claude Code en mode fallback — M1 (03 · REQ-CLA-20..31, 70..76).
/// Sources : transcripts JSONL (FSEvents + offsets) + registre PID `~/.claude/sessions/`.
/// Les hooks (source primaire temps réel) arrivent au jalon M2 et prendront l'autorité.
public actor ClaudeSessionProvider {
    private let paths: DashPaths
    private let clock: any ClockProvider

    private var tailer: TranscriptTailer?
    private var accumulators: [String: TranscriptAccumulator] = [:] // clé : chemin du .jsonl
    private var offsets: [String: UInt64] = [:]
    private var partialLines: [String: Data] = [:]
    private var registry: [String: RegistryEntry] = [:] // clé : sessionId
    private var lastPublished: [Session] = []
    private var publishScheduled = false
    private var revalidationTask: Task<Void, Never>?
    private var snapshotHandler: (@MainActor @Sendable ([Session]) -> Void)?

    /// Fenêtre de chargement initial : parse complet si `mtime` récent, sinon offset = taille
    /// (03 · REQ-CLA-28).
    private static let initialParseWindow: TimeInterval = 48 * 3600

    public init(paths: DashPaths, clock: any ClockProvider = SystemClock()) {
        self.paths = paths
        self.clock = clock
    }

    public func setSnapshotHandler(_ handler: @escaping @MainActor @Sendable ([Session]) -> Void) {
        snapshotHandler = handler
    }

    // MARK: - Cycle de vie

    public func start() {
        let startMonotonic = clock.monotonicSeconds
        registry = ClaudeRegistry.loadLiveEntries(from: paths.claudeSessionsDir)
        initialScan()
        publishNow()
        DashLog.claude.notice(
            "chargement initial Claude : \(self.accumulators.count) transcripts en \((self.clock.monotonicSeconds - startMonotonic) * 1000, format: .fixed(precision: 0)) ms"
        )

        let tailer = TranscriptTailer(
            roots: [paths.claudeProjectsDir, paths.claudeSessionsDir],
            pathSuffix: nil
        ) { [weak self] changedPaths in
            guard let self else { return }
            Task { await self.handleChanges(changedPaths) }
        }
        tailer.start()
        self.tailer = tailer

        // Boucle de réévaluation : dégrade thinking/executing → idle sans nouvelle écriture,
        // rafraîchit la liveness (PID) — 5 s, aligné sur les cadences ralenties (01 · §6).
        revalidationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.revalidate()
            }
        }
    }

    public func stop() {
        tailer?.stop()
        tailer = nil
        revalidationTask?.cancel()
        revalidationTask = nil
    }

    // MARK: - Scan initial (03 · REQ-CLA-28)

    private func initialScan() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: paths.claudeProjectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = clock.now
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let path = url.path
            if path.contains("/subagents/") {
                noteSubagent(path: path)
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(mtime) < Self.initialParseWindow {
                drainFile(path: path)
                accumulators[path]?.lastWriteAt = mtime // l'horodatage réel, pas l'heure du scan
            } else {
                offsets[path] = UInt64(values?.fileSize ?? 0)
            }
        }
    }

    // MARK: - Ingestion incrémentale

    private func handleChanges(_ changedPaths: [String]) {
        var touched = false
        for path in changedPaths {
            if path.hasSuffix(".jsonl") {
                if path.contains("/subagents/") {
                    noteSubagent(path: path)
                } else if path.contains("/projects/") {
                    drainFile(path: path)
                }
                touched = true
            } else if path.contains("/sessions") {
                registry = ClaudeRegistry.loadLiveEntries(from: paths.claudeSessionsDir)
                touched = true
            }
        }
        if touched { schedulePublish() }
    }

    private func drainFile(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = offsets[path] ?? 0
        if size < offset {
            // Troncature/réécriture → relire depuis zéro (REQ-CLA-28).
            offset = 0
            partialLines[path] = nil
            accumulators[path] = nil
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        offsets[path] = size

        var buffer = (partialLines[path] ?? Data()) + data
        let now = clock.now
        var accumulator = accumulators[path] ?? TranscriptAccumulator(filePath: path, now: now)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard lineData.count < 10_000_000 else { continue } // cap ligne géante
            if let line = String(data: lineData, encoding: .utf8) {
                accumulator.ingest(line: line, now: now)
            }
        }
        partialLines[path] = buffer.isEmpty ? nil : Data(buffer)
        accumulators[path] = accumulator
    }

    private func noteSubagent(path: String) {
        // …/projects/<proj>/<sessionId>/subagents/… → transcript parent <sessionId>.jsonl
        guard let range = path.range(of: "/subagents/") else { return }
        let sessionDir = String(path[..<range.lowerBound])
        let parentPath = sessionDir + ".jsonl"
        guard accumulators[parentPath] != nil else { return }
        // Extrait la dernière action du subagent (dernier tool_use) pour la remonter.
        let summary = Self.lastSubagentAction(path: path)
        accumulators[parentPath]?.noteSubagentActivity(file: path, summary: summary, now: clock.now)
    }

    /// Lit le tail du transcript subagent et résume son dernier tool_use (07 · REQ-SES-11).
    private static func lastSubagentAction(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Lit au plus les derniers 64 Ko (suffisant pour la dernière ligne).
        let window: UInt64 = 65_536
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var lastSummary: String?
        for lineData in data.split(separator: 0x0A) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String {
                    lastSummary = TranscriptAccumulator.summarizeToolUse(
                        name: name, input: block["input"] as? [String: Any] ?? [:])
                }
            }
        }
        return lastSummary
    }

    // MARK: - Publication (coalescée à 300 ms, 01 · §5.2)

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            self.publishScheduled = false
            self.publishNow()
        }
    }

    private func revalidate() {
        registry = ClaudeRegistry.loadLiveEntries(from: paths.claudeSessionsDir)
        publishNow()
    }

    private func publishNow() {
        let snapshot = buildSnapshot()
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        guard let handler = snapshotHandler else { return }
        Task { @MainActor in handler(snapshot) }
    }

    private func buildSnapshot() -> [Session] {
        let now = clock.now
        var bySessionID: [String: Session] = [:]

        for accumulator in accumulators.values {
            let entry = registry[accumulator.sessionId]
            let sinceWrite = now.timeIntervalSince(accumulator.lastWriteAt)

            let liveness: SessionLiveness = if entry != nil {
                .live // PID vivant dans le registre
            } else if sinceWrite < 600 {
                .live // activité récente, PID inconnu [HYPOTHÈSE pragmatique M1]
            } else {
                .ended(.exited) // REQ-CLA-76 fallback
            }

            let state: SessionState = liveness.isLive
                ? FallbackState.compute(
                    hasPendingTool: !accumulator.pendingToolUses.isEmpty,
                    lastEntryIsAssistant: accumulator.lastEntryIsAssistant,
                    lastStopReasonIsNull: accumulator.lastStopReasonIsNull,
                    secondsSinceLastWrite: sinceWrite
                )
                : .ended

            let session = Session(
                id: SessionID(agent: .claude, nativeID: accumulator.sessionId),
                state: state,
                liveness: liveness,
                title: accumulator.title ?? entry?.name ?? "",
                projectPath: accumulator.cwd ?? entry?.cwd,
                startedAt: accumulator.firstTimestamp ?? entry?.startedAt ?? accumulator.lastWriteAt,
                lastEventAt: accumulator.lastTimestamp ?? accumulator.lastWriteAt,
                host: HostResolver.resolve(
                    entrypoint: accumulator.entrypoint ?? entry?.entrypoint,
                    pid: entry?.pid
                ),
                tokens: accumulator.tokens,
                diff: accumulator.diff,
                filesTouched: accumulator.filesTouchedCount,
                commandCount: accumulator.commandCount,
                gitBranch: accumulator.gitBranch,
                model: accumulator.model,
                pid: entry?.pid,
                lastActivity: accumulator.lastActivity,
                lastReplyExcerpt: accumulator.lastReplyText.isEmpty ? nil : accumulator.lastReplyText,
                timeline: accumulator.timeline,
                subagentCount: accumulator.subagentFiles.count
            )
            // Resume multi-fichiers du même sessionId → l'activité la plus récente gagne.
            if let existing = bySessionID[accumulator.sessionId],
               existing.lastEventAt > session.lastEventAt { continue }
            bySessionID[accumulator.sessionId] = session
        }

        // Sessions du registre sans transcript (desktop fraîchement lancée, REQ-CLA-71).
        for (sessionId, entry) in registry where bySessionID[sessionId] == nil {
            bySessionID[sessionId] = Session(
                id: SessionID(agent: .claude, nativeID: sessionId),
                state: .idle,
                liveness: .live,
                title: entry.name ?? "",
                projectPath: entry.cwd,
                startedAt: entry.startedAt ?? now,
                host: HostResolver.resolve(entrypoint: entry.entrypoint, pid: entry.pid),
                pid: entry.pid
            )
        }

        return Array(bySessionID.values)
    }
}
