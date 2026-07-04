import DashCore
import Foundation
import Testing

/// Tests d'intégration croisés HookRelay ↔ HookServer avec le VRAI binaire compilé
/// (15 · REQ-TST-20/21). Le protocole n'étant pas partagé en code (01 · §3.2), ces tests
/// garantissent sa compatibilité de bout en bout, y compris le fail-open.
@Suite("Hook round-trip (binaire réel ↔ HookServer)")
struct HookRoundTripTests {
    /// Localise le binaire `agentdash-hook`. Le binaire est produit par le package racine ;
    /// le lanceur de tests le fournit via `AGENTDASH_HOOK_BINARY` (cf. scripts/test.sh).
    static func hookBinaryPath() -> String? {
        if let path = ProcessInfo.processInfo.environment["AGENTDASH_HOOK_BINARY"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let candidates = [
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "agentdash-hook").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runHook(binary: String, socket: String, stdin: String, extraEnv: [String: String] = [:]) -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--source", "claude", "--socket", socket]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try? process.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    private func tempSocket() -> String {
        NSTemporaryDirectory() + "agentdash-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test("nominal : le serveur reçoit l'événement et sa décision revient sur stdout du hook")
    func nominalRoundTrip() async throws {
        guard let binary = Self.hookBinaryPath() else {
            return // binaire absent → test sauté (voir scripts/test.sh)
        }
        let socket = tempSocket()
        let received = Mutex<String?>(nil)
        let server = HookServer(socketPath: socket) { request in
            received.set(request.envelope.eventJSON)
            request.reply(Data(#"{"decision":"ok"}"#.utf8))
        }
        try server.start()
        defer { server.stop() }

        // Laisse le listener démarrer.
        try await Task.sleep(for: .milliseconds(150))
        let result = runHook(binary: binary, socket: socket, stdin: #"{"hook_event_name":"PermissionRequest","session_id":"s1"}"#)

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains(#""decision":"ok""#))
        #expect(received.get()?.contains("PermissionRequest") == true)
    }

    @Test("fail-open : socket absent → exit 0, aucune sortie (le hook ne bloque jamais)")
    func failOpenNoServer() async throws {
        guard let binary = Self.hookBinaryPath() else {
            return // binaire absent → test sauté
        }
        let socket = tempSocket() // aucun serveur à l'écoute
        let start = Date()
        let result = runHook(binary: binary, socket: socket, stdin: #"{"hook_event_name":"PermissionRequest","session_id":"s1"}"#)
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)     // pas d'avis → dialogue natif de l'agent
        #expect(elapsed < 1.0)             // sort immédiatement (REQ-TST-20)
    }

    @Test("réponse vide du serveur (hand-in) → exit 0, stdout vide")
    func emptyReplyFailsOpen() async throws {
        guard let binary = Self.hookBinaryPath() else {
            return // binaire absent → test sauté
        }
        let socket = tempSocket()
        let server = HookServer(socketPath: socket) { request in
            request.reply(nil) // corps vide = « pas d'avis »
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(150))

        let result = runHook(binary: binary, socket: socket, stdin: #"{"hook_event_name":"PermissionRequest","session_id":"s1"}"#)
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }
}

/// Petit verrou générique pour partager un état entre le handler (queue réseau) et le test.
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func get() -> Value { lock.withLock { value } }
}
