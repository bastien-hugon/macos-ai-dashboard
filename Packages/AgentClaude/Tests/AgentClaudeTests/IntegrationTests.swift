import DashCore
import Foundation
import Testing
import TestSupport
@testable import AgentClaude

/// Boîte thread-safe pour partager un état entre le handler (queue réseau) et le test.
final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
}

/// Tests d'intégration du pipeline complet (15 · REQ-TST-20/21) : FakeAgent (client socket) →
/// HookServer → ClaudeEventRouter → DecisionEncoder → réponse, à travers un vrai socket UNIX.
@Suite("Pipeline IPC de bout en bout")
struct IPCPipelineTests {
    private func tempSocket() -> String {
        NSTemporaryDirectory() + "agentdash-itest-\(UUID().uuidString.prefix(8)).sock"
    }

    /// Démarre un serveur qui route l'événement et répond avec `decision` (décision simulée).
    private func serverEchoingDecision(_ socket: String, decision: @escaping @Sendable (PendingPrompt) -> PromptDecision) throws -> HookServer {
        let server = HookServer(socketPath: socket) { request in
            switch ClaudeEventRouter.route(request.envelope, now: Date()) {
            case .decision(let prompt):
                let body = DecisionEncoder.encode(decision(prompt), for: prompt)
                request.reply(body)
            case .telemetry, .ignore:
                request.reply(nil)
            }
        }
        try server.start()
        return server
    }

    @Test("permission → Allow : l'agent reçoit la décision allow")
    func permissionAllow() async throws {
        let socket = tempSocket()
        let server = try serverEchoingDecision(socket) { _ in .allow }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let agent = FakeAgent(socketPath: socket)
        let result = await Task.detached {
            agent.send(source: "claude", event: [
                "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp",
                "tool_name": "Bash", "tool_input": ["command": "ls", "description": "List"],
            ])
        }.value
        let json = (try? JSONSerialization.jsonObject(with: result.responseBody)) as? [String: Any]
        let inner = (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(inner?["behavior"] as? String == "allow")
    }

    @Test("permission → Deny with feedback : le message est transmis")
    func denyFeedback() async throws {
        let socket = tempSocket()
        let server = try serverEchoingDecision(socket) { _ in .deny(feedback: "trop risqué") }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let agent = FakeAgent(socketPath: socket)
        let result = await Task.detached {
            agent.send(source: "claude", event: [
                "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp",
                "tool_name": "Bash", "tool_input": ["command": "rm -rf /", "description": "danger"],
            ])
        }.value
        let json = (try? JSONSerialization.jsonObject(with: result.responseBody)) as? [String: Any]
        let inner = (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(inner?["behavior"] as? String == "deny")
        #expect(inner?["message"] as? String == "trop risqué")
    }

    @Test("télémétrie (PostToolUse) → réponse vide, fail-open")
    func telemetryEmpty() async throws {
        let socket = tempSocket()
        let server = try serverEchoingDecision(socket) { _ in .allow }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let agent = FakeAgent(socketPath: socket)
        let result = await Task.detached {
            agent.send(source: "claude", event: [
                "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
            ])
        }.value
        #expect(result.responseBody.isEmpty) // pas d'avis
    }

    @Test("fermeture distante avant réponse → onRemoteClose déclenché (REQ-ACT-08)")
    func remoteClose() async throws {
        let socket = tempSocket()
        let closed = TestBox(false)
        let server = HookServer(socketPath: socket) { request in
            request.onRemoteClose = { closed.set(true) }
            // On ne répond PAS : on attend que l'agent ferme.
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let agent = FakeAgent(socketPath: socket)
        await Task.detached {
            agent.sendAndDrop(source: "claude", event: [
                "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/tmp",
                "tool_name": "Bash", "tool_input": ["command": "ls"],
            ], afterMs: 200)
        }.value
        try await Task.sleep(for: .milliseconds(900))
        #expect(closed.get() == true)
    }

    @Test("app fermée (pas de serveur) → connexion échoue, fail-open")
    func noServer() async throws {
        let agent = FakeAgent(socketPath: tempSocket())
        let result = await Task.detached {
            agent.send(source: "claude", event: ["hook_event_name": "PermissionRequest", "session_id": "s1"], deadline: 1)
        }.value
        #expect(result.connected == false)
        #expect(result.responseBody.isEmpty)
    }
}
