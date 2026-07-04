import DashCore
import Foundation
import Testing
@testable import AgentClaude

@Suite("Parseur — cas limites (15 · REQ-TST)")
struct ParserEdgeCaseTests {
    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    @Test("streaming massif : 10 entrées du même requestId → dernière valeur, pas de somme")
    func streamingDedup() {
        var acc = TranscriptAccumulator(filePath: "/tmp/s.jsonl", now: Date())
        for i in 1...10 {
            acc.ingest(line: line([
                "type": "assistant", "requestId": "req_A", "sessionId": "s", "isSidechain": false,
                "timestamp": "2026-07-04T10:00:0\(i % 10)Z",
                "message": ["role": "assistant", "model": "m", "id": "msg", "stop_reason": i == 10 ? "end_turn" : nil as Any?,
                            "content": [], "usage": ["input_tokens": 1000, "output_tokens": i * 100]],
            ]), now: Date())
        }
        #expect(acc.tokens.outputTokens == 1000) // 10*100, la dernière, PAS 5500
        #expect(acc.tokens.inputTokens == 1000)  // compté une fois
    }

    @Test("ligne géante (100 Ko) ingérée sans crash")
    func giantLine() {
        var acc = TranscriptAccumulator(filePath: "/tmp/s.jsonl", now: Date())
        let bigText = String(repeating: "x", count: 100_000)
        acc.ingest(line: line([
            "type": "assistant", "requestId": "r", "sessionId": "s", "isSidechain": false,
            "timestamp": "2026-07-04T10:00:00Z",
            "message": ["role": "assistant", "model": "m", "id": "i", "stop_reason": "end_turn",
                        "content": [["type": "text", "text": bigText]], "usage": ["input_tokens": 1, "output_tokens": 1]],
        ]), now: Date())
        #expect(acc.lastReplyText.count <= TranscriptAccumulator.replyExcerptCap) // tronqué
    }

    @Test("cap de timeline : 300 tool calls → au plus 200 événements en mémoire")
    func timelineCap() {
        var acc = TranscriptAccumulator(filePath: "/tmp/s.jsonl", now: Date())
        for i in 1...300 {
            acc.ingest(line: line([
                "type": "assistant", "requestId": "r\(i)", "sessionId": "s", "isSidechain": false,
                "timestamp": "2026-07-04T10:00:00Z",
                "message": ["role": "assistant", "model": "m", "id": "i\(i)", "stop_reason": "tool_use",
                            "content": [["type": "tool_use", "id": "t\(i)", "name": "Bash", "input": ["command": "echo \(i)"]]],
                            "usage": ["input_tokens": 1, "output_tokens": 1]],
            ]), now: Date())
        }
        #expect(acc.timeline.count <= TranscriptAccumulator.timelineCap)
        #expect(acc.commandCount == 300) // le compteur, lui, n'est pas plafonné
    }

    @Test("types inconnus et anciens formats ignorés sans erreur (tolérance versions)")
    func unknownTypes() {
        var acc = TranscriptAccumulator(filePath: "/tmp/s.jsonl", now: Date())
        for type in ["summary", "system", "progress", "pr-link", "queue-operation", "totally-new-type"] {
            acc.ingest(line: line(["type": type, "sessionId": "s", "data": "x"]), now: Date())
        }
        #expect(acc.timeline.isEmpty) // rien de compté, aucun crash
    }
}

@Suite("Benchmark de perf (15 · REQ-TST)")
struct PerfBenchmarkTests {
    @Test("parse de 10 000 entrées sous 2 s, mémoire bornée")
    func largeTranscript() {
        var acc = TranscriptAccumulator(filePath: "/tmp/big.jsonl", now: Date())
        let template = { (i: Int) -> String in
            #"{"type":"assistant","requestId":"req_\#(i)","sessionId":"s","isSidechain":false,"timestamp":"2026-07-04T10:00:00Z","message":{"role":"assistant","model":"claude-fable-5","id":"m\#(i)","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t\#(i)","name":"Read","input":{"file_path":"/p/f\#(i).swift"}}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000}}}"#
        }
        let start = Date()
        for i in 0..<10_000 {
            acc.ingest(line: template(i), now: Date())
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "parse de 10k entrées trop lent : \(elapsed)s")
        #expect(acc.timeline.count <= TranscriptAccumulator.timelineCap) // mémoire bornée
        #expect(acc.tokens.outputTokens == 10_000 * 50) // dédup par requestId distinct → somme correcte
    }
}
