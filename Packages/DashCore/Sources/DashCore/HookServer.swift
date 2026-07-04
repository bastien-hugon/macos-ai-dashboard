import Darwin
import Foundation

/// Une requête de hook reçue sur le socket, avec sa connexion (fd) vivante.
/// `reply` écrit la réponse (une seule fois) puis ferme ; `onRemoteClose` est appelé si
/// l'agent ferme la connexion avant qu'on ait répondu (agent tué / timeout) — REQ-ACT-08.
public final class HookRequest: @unchecked Sendable {
    public let envelope: HookEnvelope
    private let fd: Int32
    private let queue: DispatchQueue
    private let replied = ManagedAtomicFlag()
    public var onRemoteClose: (@Sendable () -> Void)?

    /// Moniteur de fermeture distante à annuler avant de fermer le fd (évite un crash sur
    /// une DispatchSource active pointant un fd fermé).
    var closeMonitor: DispatchSourceRead?

    init(envelope: HookEnvelope, fd: Int32, queue: DispatchQueue) {
        self.envelope = envelope
        self.fd = fd
        self.queue = queue
    }

    /// Écrit le corps (nil = corps vide « pas d'avis ») puis ferme. Idempotent.
    public func reply(_ body: Data?) {
        guard replied.testAndSet() else { return }
        let monitor = closeMonitor
        queue.async { [fd] in
            monitor?.cancel()
            var out = body ?? Data()
            out.append(0x0A) // NDJSON
            out.withUnsafeBytes { raw in
                var total = 0
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                while total < out.count {
                    let n = write(fd, base + total, out.count - total)
                    if n <= 0 { break }
                    total += n
                }
            }
            close(fd)
        }
    }

    func fireRemoteCloseIfPending() {
        guard !replied.isSet else { return }
        onRemoteClose?()
    }
}

/// Serveur IPC des hooks (01 · §4.1) : socket UNIX POSIX, protocole NDJSON, 1 connexion =
/// 1 requête. Une `DispatchSource` sur le fd d'écoute accepte les connexions ; chaque
/// connexion est lue puis remise au handler avec une closure `reply` capturant son fd.
/// (Network.framework ne sait pas écouter sur un socket UNIX — EINVAL —, d'où le POSIX direct.)
public final class HookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookRequest) -> Void

    private let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.agentdash.hookserver", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        let socketURL = URL(fileURLWithPath: socketPath)
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); throw ServerError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buffer in
                for (i, byte) in pathBytes.enumerated() { buffer[i] = byte }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { close(fd); throw ServerError.bindFailed(errno) }
        guard listen(fd, 32) == 0 else { close(fd); throw ServerError.listenFailed(errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) // accept non bloquant
        chmod(socketPath, 0o600) // 01 · §8.3 : seul l'utilisateur courant

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
        DashLog.ipc.notice("HookServer à l'écoute")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    // MARK: - Accept / lecture

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { break } // EWOULDBLOCK ou plus de connexion en attente
            let fd = clientFD
            queue.async { [weak self] in self?.readRequest(on: fd) }
        }
    }

    /// Lit jusqu'au premier `\n` (ligne pouvant dépasser 64 Ko, 03 · REQ-CLA-11).
    private func readRequest(on fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { close(fd); return } // fermé sans ligne complète
            buffer.append(contentsOf: chunk[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                handleLine(line, fd: fd)
                return
            }
            if buffer.count > 16 * 1024 * 1024 { close(fd); return } // garde-fou
        }
    }

    private func handleLine(_ line: Data, fd: Int32) {
        guard let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: line) else {
            close(fd)
            return
        }
        let request = HookRequest(envelope: envelope, fd: fd, queue: queue)
        // Détecte la fermeture distante (agent tué / timeout) avant réponse.
        // IMPORTANT : le serveur retient FORTEMENT la requête via ce moniteur — sans cela,
        // rien ne la garde vivante entre l'appel au handler et la réponse si le handler ne
        // capture pas `request` (le cycle request→closeMonitor→handler→request est rompu par
        // `cancel()` sur reply ou fermeture distante, donc pas de fuite).
        let closeSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        closeSource.setEventHandler {
            var probe = [UInt8](repeating: 0, count: 1)
            if recv(fd, &probe, 1, Int32(MSG_PEEK)) == 0 {
                request.fireRemoteCloseIfPending()
                closeSource.cancel()
            }
        }
        request.closeMonitor = closeSource
        closeSource.resume()
        handler(request)
    }

    enum ServerError: Error {
        case socketFailed(Int32), bindFailed(Int32), listenFailed(Int32), pathTooLong
    }
}

/// Drapeau atomique test-and-set — une seule réponse par connexion.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func testAndSet() -> Bool {
        lock.withLock {
            if value { return false }
            value = true
            return true
        }
    }
}
