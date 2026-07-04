import Foundation

/// Contrat IPC entre `agentdash-hook` et l'app (01 · §4.1, protocole NDJSON version 1).
/// Ces types sont dupliqués côté binaire (HookRelay ne partage pas de code, 01 · §3.2) ;
/// la stabilité est garantie par les tests croisés.
public enum IPCProtocol {
    public static let version = 1
    /// Délai après lequel le relais rend la main à l'agent (corps vide) — laisse 5 s de marge
    /// sous le timeout de 600 s posé dans settings.json (03 · REQ-CLA-13).
    public static let hookDecisionDeadlineSeconds: Double = 595
}

/// Enveloppe écrite par `agentdash-hook` sur le socket (une ligne NDJSON).
/// `event` est le JSON brut de l'agent, ré-encodé tel quel.
public struct HookEnvelope: Codable, Sendable {
    public var v: Int
    public var id: String
    public var source: String          // "claude" | "cursor"
    public var termProgram: String?    // TERM_PROGRAM hérité de l'agent (étiquette hôte)
    public var ppid: Int32
    public var eventJSON: String       // JSON de l'événement, encodé en string

    enum CodingKeys: String, CodingKey {
        case v, id, source, ppid
        case termProgram = "term_program"
        case eventJSON = "event"
    }

    public init(v: Int = IPCProtocol.version, id: String, source: String, termProgram: String?, ppid: Int32, eventJSON: String) {
        self.v = v
        self.id = id
        self.source = source
        self.termProgram = termProgram
        self.ppid = ppid
        self.eventJSON = eventJSON
    }
}
