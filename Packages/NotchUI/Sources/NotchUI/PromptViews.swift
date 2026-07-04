import DashCore
import SwiftUI

/// Zone « Act » du panel (08 · §2) : rend le prompt focalisé avec navigation multi-prompts,
/// et route les décisions vers le PromptStore. Le focus clavier est géré par le coordinateur.
public struct PromptSectionView: View {
    let store: PromptStore
    let onDecision: (UUID, PromptDecision, DecisionSource) -> Void
    let onOpenTerminal: (PendingPrompt) -> Void
    let onTextFieldFocusChange: (Bool) -> Void

    public init(
        store: PromptStore,
        onDecision: @escaping (UUID, PromptDecision, DecisionSource) -> Void,
        onOpenTerminal: @escaping (PendingPrompt) -> Void,
        onTextFieldFocusChange: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.onDecision = onDecision
        self.onOpenTerminal = onOpenTerminal
        self.onTextFieldFocusChange = onTextFieldFocusChange
    }

    public var body: some View {
        if let prompt = store.focusedPrompt {
            VStack(alignment: .leading, spacing: 8) {
                header(prompt)
                PromptCardView(
                    prompt: prompt,
                    onDecision: { decision, source in onDecision(prompt.id, decision, source) },
                    onOpenTerminal: { onOpenTerminal(prompt) },
                    onTextFieldFocusChange: onTextFieldFocusChange
                )
                .id(prompt.id) // reset des @State (champ texte, sélections) au changement de prompt
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 1, green: 0.72, blue: 0.2).opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color(red: 1, green: 0.72, blue: 0.2).opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }

    @ViewBuilder private func header(_ prompt: PendingPrompt) -> some View {
        HStack(spacing: 6) {
            Image(systemName: promptIcon(prompt))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.2))
            Text(prompt.sessionLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if store.prompts.count > 1 {
                let others = store.prompts.count - 1
                Text("+\(others) waiting")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Button { focusPrev(prompt) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                Button { focusNext(prompt) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white.opacity(0.6))
    }

    private func promptIcon(_ prompt: PendingPrompt) -> String {
        switch prompt.payload {
        case .permission: "hand.raised.fill"
        case .plan: "list.clipboard.fill"
        case .question: "questionmark.circle.fill"
        }
    }

    private func focusNext(_ prompt: PendingPrompt) {
        guard let index = store.prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        store.focus(store.prompts[(index + 1) % store.prompts.count].id)
    }

    private func focusPrev(_ prompt: PendingPrompt) {
        guard let index = store.prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        store.focus(store.prompts[(index - 1 + store.prompts.count) % store.prompts.count].id)
    }
}

/// Rend une carte selon le type de payload.
struct PromptCardView: View {
    let prompt: PendingPrompt
    let onDecision: (PromptDecision, DecisionSource) -> Void
    let onOpenTerminal: () -> Void
    let onTextFieldFocusChange: (Bool) -> Void

    var body: some View {
        switch prompt.payload {
        case .permission(let request):
            PermissionCardView(prompt: prompt, request: request,
                               onDecision: onDecision, onOpenTerminal: onOpenTerminal,
                               onTextFieldFocusChange: onTextFieldFocusChange)
        case .plan(let plan):
            PlanCardView(plan: plan, onDecision: onDecision, onOpenTerminal: onOpenTerminal)
        case .question(let question):
            QuestionCardView(question: question, onDecision: onDecision,
                            onTextFieldFocusChange: onTextFieldFocusChange)
        }
    }
}

// MARK: - Permission

struct PermissionCardView: View {
    let prompt: PendingPrompt
    let request: PermissionRequest
    let onDecision: (PromptDecision, DecisionSource) -> Void
    let onOpenTerminal: () -> Void
    let onTextFieldFocusChange: (Bool) -> Void

    @State private var showFeedback = false
    @State private var feedback = ""
    @State private var expanded = false
    @FocusState private var feedbackFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            // Reformulation honnête (REQ-ACT-14/15).
            if let opaque = request.effectsOpaqueReason {
                Label(opaque, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
            } else if !request.honestEffects.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(request.honestEffects, id: \.self) { effect in
                        Label(effect, systemImage: "pencil.line")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            if let command = request.commandText {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(expanded ? nil : 4) // prompts extensibles (REQ-ACT-35)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
                if command.components(separatedBy: "\n").count > 4 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            } else if let file = request.filePath {
                Text((file as NSString).lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }

            if showFeedback {
                feedbackField
            } else {
                actions
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            PromptButton(title: "Allow", shortcut: "⌘A", kind: .primary) {
                onDecision(.allow, .notch)
            }
            PromptButton(title: "Deny", shortcut: "⌘N", kind: .normal) {
                onDecision(.deny(feedback: nil), .notch)
            }
            if prompt.capabilities.canAlwaysAllow {
                PromptButton(title: "Always", shortcut: "⌥A", kind: .normal) {
                    onDecision(.alwaysAllow(request.suggestions[0]), .notch)
                }
            }
            Spacer()
            Button("Deny with feedback…") { showFeedback = true; feedbackFocused = true }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var feedbackField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Reason (sent to the agent)…", text: $feedback, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
                .focused($feedbackFocused)
                .onExitCommand { feedbackFocused = false } // Échap rend le focus (REQ-NUI-56)
            HStack {
                PromptButton(title: "Send", shortcut: nil, kind: .primary) {
                    onDecision(.deny(feedback: feedback), .notch)
                }
                PromptButton(title: "Cancel", shortcut: nil, kind: .normal) {
                    showFeedback = false; feedback = ""
                }
            }
        }
        .onChange(of: feedbackFocused) { _, focused in onTextFieldFocusChange(focused) }
    }
}

// MARK: - Plan

struct PlanCardView: View {
    let plan: PlanProposal
    let onDecision: (PromptDecision, DecisionSource) -> Void
    let onOpenTerminal: () -> Void

    @State private var expanded = false
    @State private var acceptEdits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            ScrollView {
                Text((try? AttributedString(markdown: plan.markdown,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(plan.markdown))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: expanded ? 400 : 200) // REQ-ACT-35
            if plan.markdown.count > 400 {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            if !plan.allowedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Will request:").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    ForEach(plan.allowedPrompts, id: \.self) {
                        Text("• \($0)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            Toggle("Switch to Accept Edits", isOn: $acceptEdits)
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 6) {
                PromptButton(title: "Approve", shortcut: "⌘A", kind: .primary) {
                    onDecision(.approvePlan(switchToAcceptEdits: acceptEdits), .notch)
                }
                PromptButton(title: "Reject", shortcut: "⌘N", kind: .normal) {
                    onDecision(.rejectPlan(feedback: ""), .notch)
                }
            }
        }
    }
}

// MARK: - Questions

struct QuestionCardView: View {
    let question: QuestionPrompt
    let onDecision: (PromptDecision, DecisionSource) -> Void
    let onTextFieldFocusChange: (Bool) -> Void

    @State private var selections: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    @FocusState private var focusedQuestion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(question.questions) { q in
                VStack(alignment: .leading, spacing: 5) {
                    if let header = q.header {
                        Text(header).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4)).textCase(.uppercase)
                    }
                    Text(q.text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    FlowLayout(spacing: 5) {
                        ForEach(q.options, id: \.self) { option in
                            optionPill(q, option)
                        }
                    }
                    if q.allowsFreeText {
                        TextField("Type your own answer…", text: binding(for: q))
                            .textFieldStyle(.plain).font(.system(size: 11))
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.4)))
                            .focused($focusedQuestion, equals: q.id)
                            .onExitCommand { focusedQuestion = nil } // Échap rend le focus (REQ-NUI-56)
                    }
                }
            }
            PromptButton(title: "Submit", shortcut: "⏎", kind: .primary, disabled: !canSubmit) {
                submit()
            }
        }
        .onChange(of: focusedQuestion) { _, value in onTextFieldFocusChange(value != nil) }
    }

    private func optionPill(_ q: AgentQuestion, _ option: String) -> some View {
        let selected = selections[q.id]?.contains(option) == true
        return Button {
            toggle(q, option)
        } label: {
            Text(option)
                .font(.system(size: 11))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08)))
                .foregroundStyle(selected ? .white : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func binding(for q: AgentQuestion) -> Binding<String> {
        Binding(
            get: { freeText[q.id] ?? "" },
            set: { newValue in
                freeText[q.id] = newValue
                if !newValue.isEmpty { selections[q.id] = [] } // texte désélectionne les pilules
            }
        )
    }

    private func toggle(_ q: AgentQuestion, _ option: String) {
        freeText[q.id] = "" // pilule désélectionne le texte
        var set = selections[q.id] ?? []
        if q.multiSelect {
            if set.contains(option) { set.remove(option) } else { set.insert(option) }
        } else {
            set = [option]
        }
        selections[q.id] = set
    }

    private var canSubmit: Bool {
        question.questions.allSatisfy { q in
            !(selections[q.id]?.isEmpty ?? true) || !(freeText[q.id]?.isEmpty ?? true)
        }
    }

    private func submit() {
        var answers: [String: String] = [:]
        for q in question.questions {
            if let text = freeText[q.id], !text.isEmpty {
                answers[q.id] = text
            } else if let set = selections[q.id], !set.isEmpty {
                // Ordre stable : suit l'ordre des options d'origine.
                answers[q.id] = q.options.filter { set.contains($0) }.joined(separator: ", ")
            }
        }
        onDecision(.answers(answers), .notch)
    }
}
