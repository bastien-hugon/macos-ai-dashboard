import DashCore
import Darwin
import Foundation

/// Client socket qui imite un agent réel (Claude Code / Cursor) : se connecte au
/// `HookServer`, envoie une enveloppe NDJSON, attend la réponse. Permet de tester tout
/// le pipeline IPC de bout en bout sans le vrai binaire (15 · REQ-TST-20/21).
public final class FakeAgent: @unchecked Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public struct Result: Sendable {
        public let responseBody: Data   // corps sans le \n terminal (vide = fail-open)
        public let connected: Bool
    }

    /// Envoie un événement (JSON brut de l'agent) et attend la réponse (deadline en s).
    /// Bloquant — à appeler depuis une tâche de test.
    public func send(source: String, event: [String: Any], deadline: TimeInterval = 5) -> Result {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return Result(responseBody: Data(), connected: false) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return Result(responseBody: Data(), connected: false)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return Result(responseBody: Data(), connected: false) }

        // Enveloppe NDJSON comme le vrai binaire.
        let eventJSON = String(data: (try? JSONSerialization.data(withJSONObject: event)) ?? Data(), encoding: .utf8) ?? "{}"
        let envelope: [String: Any] = ["v": 1, "id": UUID().uuidString, "source": source, "ppid": 999, "event": eventJSON]
        var payload = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }

        // Lecture de la réponse jusqu'au \n avec deadline.
        var response = Data()
        let start = Date()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while Date().timeIntervalSince(start) < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready <= 0 { continue }
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0..<n])
            if let newline = response.firstIndex(of: 0x0A) {
                return Result(responseBody: Data(response[response.startIndex..<newline]), connected: true)
            }
        }
        return Result(responseBody: response, connected: true)
    }

    /// Se connecte, envoie, puis ferme brutalement AVANT la réponse (agent tué / timeout).
    /// Retourne le fd resté ouvert pour que le test contrôle la fermeture.
    public func sendAndDrop(source: String, event: [String: Any], afterMs: Int) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return }
        let eventJSON = String(data: (try? JSONSerialization.data(withJSONObject: event)) ?? Data(), encoding: .utf8) ?? "{}"
        let envelope: [String: Any] = ["v": 1, "id": UUID().uuidString, "source": source, "ppid": 999, "event": eventJSON]
        var payload = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        usleep(useconds_t(afterMs * 1000))
        close(fd) // fermeture brutale → le serveur doit détecter onRemoteClose
    }
}
