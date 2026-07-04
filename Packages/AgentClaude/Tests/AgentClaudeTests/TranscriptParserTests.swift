import DashCore
import Foundation
import Testing
@testable import AgentClaude

/// Fixtures anonymisées calquées sur le format réel observé (research claude-code §3.3).
private enum Fixtures {
    static let userPrompt = """
    {"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"Refactor the auth flow please"}]},"uuid":"u-1","timestamp":"2026-07-03T10:00:00.000Z","cwd":"/Users/test/Documents/my-project","sessionId":"s-1","version":"2.1.199","gitBranch":"main","entrypoint":"claude-vscode","userType":"external"}
    """

    static func assistantUsage(requestId: String, output: Int, stopReason: String?) -> String {
        let stop = stopReason.map { "\"\($0)\"" } ?? "null"
        return """
        {"type":"assistant","requestId":"\(requestId)","uuid":"a-\(requestId)-\(output)","parentUuid":"u-1","timestamp":"2026-07-03T10:00:05.000Z","sessionId":"s-1","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_1","role":"assistant","content":[{"type":"text","text":"Working on it."}],"stop_reason":\(stop),"usage":{"input_tokens":5381,"cache_creation_input_tokens":4995,"cache_read_input_tokens":7926,"output_tokens":\(output),"service_tier":"standard"}}}
        """
    }

    static let assistantToolUse = """
    {"type":"assistant","requestId":"req_B","uuid":"a-tool","parentUuid":"a-req_A-243","timestamp":"2026-07-03T10:00:10.000Z","sessionId":"s-1","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_2","role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"git status","description":"Show working tree status"}},{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"/Users/test/Documents/my-project/Sources/Auth.swift"}}],"stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
    """

    static let toolResultWithPatch = """
    {"type":"user","uuid":"u-2","parentUuid":"a-tool","timestamp":"2026-07-03T10:00:12.000Z","sessionId":"s-1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"ok"}]},"toolUseResult":{"filePath":"/Users/test/Documents/my-project/Sources/Auth.swift","structuredPatch":[{"lines":["+let a = 1","+let b = 2","-let old = 0"," context"]}],"userModified":false}}
    """

    static let aiTitle = """
    {"type":"ai-title","aiTitle":"Refactor the authentication flow","uuid":"t-1","sessionId":"s-1","timestamp":"2026-07-03T10:00:15.000Z"}
    """

    static let unknownType = """
    {"type":"file-history-snapshot","messageId":"m-1","snapshot":{}}
    """

    static let sidechainEntry = """
    {"type":"assistant","isSidechain":true,"uuid":"sc-1","timestamp":"2026-07-03T10:00:16.000Z","sessionId":"s-1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_99","name":"Bash","input":{"command":"ls"}}],"stop_reason":null,"usage":{"input_tokens":999999,"output_tokens":999999}}}
    """
}

@Suite("TranscriptAccumulator")
struct TranscriptAccumulatorTests {
    private func makeAccumulator(lines: [String]) -> TranscriptAccumulator {
        var acc = TranscriptAccumulator(filePath: "/tmp/s-1.jsonl", now: Date())
        for line in lines { acc.ingest(line: line, now: Date()) }
        return acc
    }

    @Test("dédup des tokens par requestId : la dernière entrée du stream gagne")
    func tokenDedup() {
        let acc = makeAccumulator(lines: [
            Fixtures.userPrompt,
            Fixtures.assistantUsage(requestId: "req_A", output: 100, stopReason: nil),
            Fixtures.assistantUsage(requestId: "req_A", output: 243, stopReason: "end_turn"),
        ])
        #expect(acc.tokens.outputTokens == 243) // jamais 343 (REQ-CLA-24)
        #expect(acc.tokens.inputTokens == 5381)
        #expect(acc.tokens.cacheReadTokens == 7926)
        #expect(acc.tokens.totalInputConsumption == 5381 + 7926 + 4995)
    }

    @Test("tool_use : compteurs, pending, appariement par tool_use_id, diffs structuredPatch")
    func toolLifecycle() {
        var acc = makeAccumulator(lines: [
            Fixtures.userPrompt,
            Fixtures.assistantToolUse,
        ])
        #expect(acc.commandCount == 1)
        #expect(acc.filesTouchedCount == 1)
        #expect(acc.pendingToolUses.count == 2)

        acc.ingest(line: Fixtures.toolResultWithPatch, now: Date())
        #expect(acc.pendingToolUses.count == 1) // toolu_02 apparié, toolu_01 encore pending
        #expect(acc.diff == DiffStats(added: 2, removed: 1)) // REQ-CLA-23
    }

    @Test("métadonnées : titre ai-title, cwd, branche, modèle, entrypoint, sessionId")
    func metadata() {
        let acc = makeAccumulator(lines: [
            Fixtures.userPrompt,
            Fixtures.assistantUsage(requestId: "req_A", output: 10, stopReason: "end_turn"),
            Fixtures.aiTitle,
        ])
        #expect(acc.sessionId == "s-1")
        #expect(acc.title == "Refactor the authentication flow")
        #expect(acc.cwd == "/Users/test/Documents/my-project")
        #expect(acc.gitBranch == "main")
        #expect(acc.model == "claude-fable-5")
        #expect(acc.entrypoint == "claude-vscode")
    }

    @Test("tolérance : lignes invalides, types inconnus et sidechain ignorés sans erreur")
    func tolerance() {
        let acc = makeAccumulator(lines: [
            "not json at all {{{",
            Fixtures.unknownType,
            Fixtures.sidechainEntry, // REQ-CLA-25 : jamais compté dans la session racine
            Fixtures.userPrompt,
        ])
        #expect(acc.tokens.isEmpty)     // l'usage sidechain n'a pas été compté
        #expect(acc.commandCount == 0)  // le tool_use sidechain non plus
        #expect(acc.cwd == "/Users/test/Documents/my-project")
    }

    @Test("timeline et activité : résumés en langage clair, prompt reset l'extrait")
    func timelineAndActivity() {
        let acc = makeAccumulator(lines: [
            Fixtures.userPrompt,
            Fixtures.assistantUsage(requestId: "req_A", output: 10, stopReason: nil),
            Fixtures.assistantToolUse,
        ])
        #expect(acc.lastActivity == "Edited Auth.swift") // dernier tool_use de l'entrée
        #expect(acc.timeline.count == 3) // prompt + 2 tool calls
        #expect(acc.timeline.first?.kind == .prompt)
        // La description du Bash est utilisée comme résumé (résumé en langage clair).
        #expect(acc.timeline[1].summary == "Show working tree status")
        #expect(acc.lastReplyText.contains("Working on it."))
    }
}

@Suite("FallbackState (03 · REQ-CLA-31)")
struct FallbackStateTests {
    @Test("un outil long reste executing, jamais waiting (AC-08)")
    func longToolStaysExecuting() {
        let state = FallbackState.compute(
            hasPendingTool: true, lastEntryIsAssistant: true,
            lastStopReasonIsNull: false, secondsSinceLastWrite: 180
        )
        #expect(state == .executing)
    }

    @Test("stop_reason null récent → thinking ; au-delà de 10 s → idle")
    func thinkingDegradesToIdle() {
        #expect(FallbackState.compute(
            hasPendingTool: false, lastEntryIsAssistant: true,
            lastStopReasonIsNull: true, secondsSinceLastWrite: 5
        ) == .thinking)
        #expect(FallbackState.compute(
            hasPendingTool: false, lastEntryIsAssistant: true,
            lastStopReasonIsNull: true, secondsSinceLastWrite: 20
        ) == .idle)
    }

    @Test("end_turn sans écriture → idle ; waiting jamais inféré")
    func idleAndNeverWaiting() {
        let state = FallbackState.compute(
            hasPendingTool: false, lastEntryIsAssistant: true,
            lastStopReasonIsNull: false, secondsSinceLastWrite: 60
        )
        #expect(state == .idle)
        #expect(state != .waiting)
    }

    @Test("outil pending abandonné depuis 30 min → idle (session morte en plein outil)")
    func stalePendingTool() {
        #expect(FallbackState.compute(
            hasPendingTool: true, lastEntryIsAssistant: true,
            lastStopReasonIsNull: false, secondsSinceLastWrite: 2000
        ) == .idle)
    }
}
