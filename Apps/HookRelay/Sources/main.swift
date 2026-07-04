// agentdash-hook — binaire compagnon relais des hooks (01 · §3.1, 03 · REQ-CLA-10..14).
//
// Rôle : lire l'événement JSON de l'agent sur stdin, l'envelopper (NDJSON), l'envoyer au
// socket UNIX de l'app, attendre au plus une réponse et l'écrire TELLE QUELLE sur stdout.
//
// CONTRAT ABSOLU — fail-open (REQ-CLA-12) : toute anomalie (socket absent, refusé, réponse
// tardive, JSON invalide, app fermée) ⇒ `exit 0` SANS rien écrire sur stdout → l'agent
// applique son comportement natif. Le binaire ne doit JAMAIS bloquer une session.
//
// Aucune dépendance hors Darwin/Foundation : binaire minimal, spawn rapide. Le protocole
// NDJSON est dupliqué ici (pas de partage de code avec l'app, 01 · §3.2) ; les tests croisés
// garantissent la compatibilité.
import Darwin
import Foundation

// --- Arguments : --source claude|cursor, --socket <path> (override optionnel) ---
var source = "claude"
var socketOverride: String?
do {
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--source": if let value = iterator.next() { source = value }
        case "--socket": if let value = iterator.next() { socketOverride = value }
        default: break
        }
    }
}

/// Deadline dur : au-delà, on rend la main à l'agent (l'agent a son propre timeout de 600 s ;
/// on reste bien en deçà, une décision humaine peut prendre des minutes → 595 s).
let deadline: TimeInterval = 595

func failOpen() -> Never { exit(0) }

// --- Lire tout stdin (ligne pouvant dépasser 64 Ko, REQ-CLA-11) ---
let stdinData = FileHandle.standardInput.readDataToEndOfFile()

// --- Résoudre le chemin du socket (même logique que DashPaths, dupliquée) ---
func resolveSocketPath(_ override: String?) -> String {
    if let override { return override }
    if let env = ProcessInfo.processInfo.environment["AGENTDASH_SOCKET_OVERRIDE"], !env.isEmpty {
        return env
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let preferred = home + "/Library/Application Support/AgentDash/agentdash.sock"
    if preferred.utf8.count < 100 { return preferred }
    return NSTemporaryDirectory() + "agentdash.sock"
}

// --- Construire l'enveloppe NDJSON ---
let eventString = String(data: stdinData, encoding: .utf8) ?? ""
var envelope: [String: Any] = [
    "v": 1,
    "id": UUID().uuidString,
    "source": source,
    "ppid": getppid(),
    "event": eventString,
]
if let term = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
    envelope["term_program"] = term
}
guard var payload = try? JSONSerialization.data(withJSONObject: envelope) else { failOpen() }
payload.append(0x0A)

// --- Connexion socket UNIX bloquante avec deadline ---
let path = resolveSocketPath(socketOverride)
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { failOpen() }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = path.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { failOpen() }
withUnsafeMutablePointer(to: &addr.sun_path) { dst in
    dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buffer in
        for (i, byte) in pathBytes.enumerated() { buffer[i] = byte }
    }
}
let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        connect(fd, sockaddrPtr, addrLen)
    }
}
guard connected == 0 else { failOpen() } // app fermée → ENOENT/refus → fail-open (REQ-CLA-12)

// --- Écrire la requête ---
let written = payload.withUnsafeBytes { raw -> Int in
    var total = 0
    let base = raw.bindMemory(to: UInt8.self).baseAddress!
    while total < payload.count {
        let n = write(fd, base + total, payload.count - total)
        if n <= 0 { return -1 }
        total += n
    }
    return total
}
guard written == payload.count else { failOpen() }

// --- Attendre la réponse (jusqu'au premier \n) avec deadline via poll() ---
var response = Data()
let start = Date()
var buffer = [UInt8](repeating: 0, count: 65536)
readLoop: while true {
    let remaining = deadline - Date().timeIntervalSince(start)
    if remaining <= 0 { failOpen() } // pas de décision à temps → dialogue natif
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
    if ready < 0 { failOpen() }
    if ready == 0 { continue } // timeout de tick, on re-vérifie la deadline globale
    let n = read(fd, &buffer, buffer.count)
    if n < 0 { failOpen() }
    if n == 0 { break } // connexion fermée par l'app sans \n → fail-open plus bas
    response.append(contentsOf: buffer[0..<n])
    if let newline = response.firstIndex(of: 0x0A) {
        response = response[response.startIndex..<newline]
        break
    }
}

// --- Réponse vide = « pas d'avis » (auto-libération / hand-in) → fail-open silencieux ---
guard !response.isEmpty else { failOpen() }

// --- Écrire la décision telle quelle sur stdout, exit 0 ---
FileHandle.standardOutput.write(response)
exit(0)
