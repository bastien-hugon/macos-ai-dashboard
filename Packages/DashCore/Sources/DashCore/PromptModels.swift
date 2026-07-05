import Foundation

/// Prompts actionnables (02 · §4). Le payload est agent-agnostique ; les capacités
/// déclarent ce que l'UI peut proposer (⌥A Claude uniquement, réponses inline, etc.).

public struct PermissionSuggestion: Codable, Hashable, Sendable {
    public struct Rule: Codable, Hashable, Sendable {
        public var toolName: String
        public var ruleContent: String?
        public init(toolName: String, ruleContent: String?) {
            self.toolName = toolName
            self.ruleContent = ruleContent
        }
    }
    public var type: String
    public var rules: [Rule]?
    public var behavior: String?
    public var destination: String?
    public var mode: String?

    public init(type: String, rules: [Rule]? = nil, behavior: String? = nil, destination: String? = nil, mode: String? = nil) {
        self.type = type
        self.rules = rules
        self.behavior = behavior
        self.destination = destination
        self.mode = mode
    }
}

public struct PermissionRequest: Hashable, Sendable {
    public var toolName: String
    public var displayTitle: String
    public var commandText: String?    // commande brute (Bash) pour affichage monospace
    public var filePath: String?       // Edit/Write
    public var suggestions: [PermissionSuggestion]
    public var cwd: String
    /// Effets d'écriture détectés localement (reformulation « honnête », REQ-ACT-14).
    public var honestEffects: [String]
    public var effectsOpaqueReason: String?

    public init(toolName: String, displayTitle: String, commandText: String? = nil, filePath: String? = nil, suggestions: [PermissionSuggestion] = [], cwd: String, honestEffects: [String] = [], effectsOpaqueReason: String? = nil) {
        self.toolName = toolName
        self.displayTitle = displayTitle
        self.commandText = commandText
        self.filePath = filePath
        self.suggestions = suggestions
        self.cwd = cwd
        self.honestEffects = honestEffects
        self.effectsOpaqueReason = effectsOpaqueReason
    }
}

public struct AgentQuestion: Identifiable, Hashable, Sendable {
    public var id: String              // le TEXTE de la question (clé du mapping answers)
    public var header: String?
    public var text: String
    public var options: [String]
    public var multiSelect: Bool
    public var allowsFreeText: Bool

    public init(id: String, header: String?, text: String, options: [String], multiSelect: Bool, allowsFreeText: Bool = true) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
        self.allowsFreeText = allowsFreeText
    }
}

public struct QuestionPrompt: Hashable, Sendable {
    public var questions: [AgentQuestion]
    /// Nom de tool d'origine (pour ré-encoder `updatedInput`).
    public var toolName: String
    /// Input original du tool (renvoyé tel quel dans updatedInput, augmenté de `answers`).
    public var originalInputJSON: String
    /// Le prompt est-il arrivé par PreToolUse (secours) plutôt que PermissionRequest ?
    public var viaPreToolUse: Bool

    public init(questions: [AgentQuestion], toolName: String, originalInputJSON: String, viaPreToolUse: Bool) {
        self.questions = questions
        self.toolName = toolName
        self.originalInputJSON = originalInputJSON
        self.viaPreToolUse = viaPreToolUse
    }
}

public struct PlanProposal: Hashable, Sendable {
    public var markdown: String
    public var planFilePath: String?
    public var allowedPrompts: [String]  // « tool: prompt » aplati pour l'affichage
    public var title: String
    public var viaPreToolUse: Bool

    public init(markdown: String, planFilePath: String? = nil, allowedPrompts: [String] = [], title: String, viaPreToolUse: Bool) {
        self.markdown = markdown
        self.planFilePath = planFilePath
        self.allowedPrompts = allowedPrompts
        self.title = title
        self.viaPreToolUse = viaPreToolUse
    }
}

public enum PendingPromptPayload: Hashable, Sendable {
    case permission(PermissionRequest)
    case question(QuestionPrompt)
    case plan(PlanProposal)
}

public struct PromptCapabilities: Hashable, Sendable {
    public var canAlwaysAllow: Bool
    public var canDenyWithFeedback: Bool
    public var canAnswerInline: Bool
    public var canApprovePlan: Bool
    public var canHandInToTerminal: Bool

    public init(canAlwaysAllow: Bool, canDenyWithFeedback: Bool, canAnswerInline: Bool, canApprovePlan: Bool, canHandInToTerminal: Bool) {
        self.canAlwaysAllow = canAlwaysAllow
        self.canDenyWithFeedback = canDenyWithFeedback
        self.canAnswerInline = canAnswerInline
        self.canApprovePlan = canApprovePlan
        self.canHandInToTerminal = canHandInToTerminal
    }
}

public struct PendingPrompt: Identifiable, Sendable {
    public let id: UUID
    public let sessionID: SessionID
    public let receivedAt: Date
    public let expiresAt: Date
    public var payload: PendingPromptPayload
    public var capabilities: PromptCapabilities
    /// Étiquette de session pour la file multi-prompts (agent + projet + titre).
    public var sessionLabel: String
    public var termProgram: String?
    public var ppid: Int32?

    public init(id: UUID = UUID(), sessionID: SessionID, receivedAt: Date, expiresAt: Date, payload: PendingPromptPayload, capabilities: PromptCapabilities, sessionLabel: String, termProgram: String? = nil, ppid: Int32? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
        self.payload = payload
        self.capabilities = capabilities
        self.sessionLabel = sessionLabel
        self.termProgram = termProgram
        self.ppid = ppid
    }
}

public enum PromptDecision: Sendable {
    case allow
    case alwaysAllow(PermissionSuggestion)
    case deny(feedback: String?)
    case answers([String: String])
    case approvePlan(switchToAcceptEdits: Bool)
    case rejectPlan(feedback: String)
    case handInToTerminal
}

public enum DecisionSource: String, Sendable {
    case notch, hotkey, notification, terminal, timeout, auto
}

/// Garde de l'auto-accept opt-in (par agent) : seules les demandes de **permission** sont
/// auto-acceptées — jamais les plans ni les questions (décisions de contenu qui méritent
/// un humain). Fonction pure, testée dans DashCoreTests.
public enum AutoAcceptGate {
    public static func shouldAutoAccept(_ prompt: PendingPrompt, claudeEnabled: Bool, cursorEnabled: Bool) -> Bool {
        guard case .permission = prompt.payload else { return false }
        switch prompt.sessionID.agent {
        case .claude: return claudeEnabled
        case .cursor: return cursorEnabled
        }
    }
}

public enum PermissionOutcome: Sendable {
    case granted(via: DecisionSource)
    case denied(via: DecisionSource)
    case released
}
