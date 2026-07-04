import Foundation
import Observation

/// File des prompts actionnables (08 · §3.2). Invariant : 1 connexion IPC ouverte ⇔
/// 1 `PendingPrompt` vivant. Toutes les mutations sur MainActor ; `reply` renvoie la
/// décision sur la queue réseau du HookServer.
@MainActor @Observable
public final class PromptStore {
    public private(set) var prompts: [PendingPrompt] = []
    public private(set) var focusedPromptID: UUID?

    /// Callback vers SessionStore pour la transition d'état optimiste (injecté par la
    /// composition root pour éviter une dépendance dure entre stores).
    public var onDecision: (@MainActor (SessionID, PromptDecision, DecisionSource) -> Void)?
    /// Notifié après toute mutation (enqueue/decide/focus/retire) : la surface se resynchronise
    /// (auto-expand, hotkeys, focus clavier). `wasEmptyBefore` distingue une première arrivée.
    /// Possédé par le coordinateur du notch.
    public var onChange: (@MainActor (_ hasActionable: Bool, _ becameActionable: Bool) -> Void)?
    /// Notifié à l'arrivée d'un nouveau prompt (pour poster une notification système).
    public var onPromptArrived: (@MainActor (PendingPrompt) -> Void)?

    private var replies: [UUID: @Sendable (Data?) -> Void] = [:]

    public init() {}

    public var focusedPrompt: PendingPrompt? {
        prompts.first { $0.id == focusedPromptID }
    }

    public var hasActionablePrompt: Bool { !prompts.isEmpty }
    public var pendingCount: Int { prompts.count }
    public var hasPendingPrompt: Bool { !prompts.isEmpty }

    // MARK: - Ingestion (EventRouter → MainActor)

    public func enqueue(_ prompt: PendingPrompt, reply: @escaping @Sendable (Data?) -> Void) {
        let wasEmpty = prompts.isEmpty
        replies[prompt.id] = reply
        prompts.append(prompt)
        prompts.sort { $0.receivedAt < $1.receivedAt } // FIFO (REQ-ACT-31)
        if focusedPromptID == nil { focusedPromptID = prompt.id }
        onPromptArrived?(prompt)
        onChange?(true, wasEmpty)
    }

    // MARK: - Décision utilisateur

    /// Idempotent (REQ-ACT-05) : un second appel pour le même id est un no-op.
    public func decide(_ id: UUID, _ decision: PromptDecision, via source: DecisionSource) {
        guard let prompt = prompts.first(where: { $0.id == id }),
              let reply = replies[id] else { return }
        reply(DecisionEncoder.encode(decision, for: prompt))
        onDecision?(prompt.sessionID, decision, source)
        remove(id)
    }

    public func focus(_ id: UUID) {
        guard prompts.contains(where: { $0.id == id }) else { return }
        focusedPromptID = id
        onChange?(true, false)
    }

    /// Retrait sur connexion fermée côté distant ou obsolescence (REQ-ACT-08/09) —
    /// aucune réponse écrite (la connexion est déjà morte).
    public func retire(_ id: UUID, outcome: PermissionOutcome) {
        replies[id] = nil
        remove(id)
    }

    /// Auto-libération des prompts arrivés à expiration (REQ-ACT-07) — tick 1 s.
    public func releaseExpired(now: Date) {
        for prompt in prompts where prompt.expiresAt <= now {
            if let reply = replies[prompt.id] { reply(nil) } // corps vide → dialogue natif
            onDecision?(prompt.sessionID, .handInToTerminal, .timeout)
            remove(prompt.id)
        }
    }

    // MARK: -

    private func remove(_ id: UUID) {
        replies[id] = nil
        prompts.removeAll { $0.id == id }
        if focusedPromptID == id {
            focusedPromptID = prompts.first?.id
        }
        onChange?(!prompts.isEmpty, false)
    }
}
