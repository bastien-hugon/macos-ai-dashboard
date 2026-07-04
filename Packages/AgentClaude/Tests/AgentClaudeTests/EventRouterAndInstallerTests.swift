import DashCore
import Foundation
import Testing
import TestSupport
@testable import AgentClaude

@Suite("ClaudeEventRouter (03 · REQ-CLA-13)")
struct ClaudeEventRouterTests {
    private func envelope(event: [String: Any]) -> HookEnvelope {
        let json = String(data: try! JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
        return HookEnvelope(id: "1", source: "claude", termProgram: "iTerm.app", ppid: 42, eventJSON: json)
    }

    @Test("PermissionRequest Bash → prompt permission avec effets honnêtes + always-allow")
    func permissionRequest() {
        let env = envelope(event: [
            "hook_event_name": "PermissionRequest",
            "session_id": "s1", "cwd": "/Users/x/proj",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build", "description": "Clean build"],
            "permission_suggestions": [[
                "type": "addRules",
                "rules": [["toolName": "Bash", "ruleContent": "rm -rf build"]],
                "behavior": "allow", "destination": "localSettings",
            ]],
        ])
        guard case .decision(let prompt) = ClaudeEventRouter.route(env, now: Date()) else {
            Issue.record("attendu .decision"); return
        }
        #expect(prompt.capabilities.canAlwaysAllow) // suggestions présentes
        guard case .permission(let request) = prompt.payload else { Issue.record("attendu permission"); return }
        #expect(request.commandText == "rm -rf build")
        #expect(request.honestEffects.contains { $0.contains("Deletes") })
        #expect(prompt.termProgram == "iTerm.app")
    }

    @Test("PreToolUse ExitPlanMode → prompt plan avec titre H1")
    func planPrompt() {
        let env = envelope(event: [
            "hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/p",
            "tool_name": "ExitPlanMode",
            "tool_input": ["plan": "# Refactor auth\nDo the thing."],
        ])
        guard case .decision(let prompt) = ClaudeEventRouter.route(env, now: Date()),
              case .plan(let plan) = prompt.payload else { Issue.record("attendu plan"); return }
        #expect(plan.title == "Refactor auth")
        #expect(plan.viaPreToolUse)
        #expect(prompt.capabilities.canApprovePlan)
    }

    @Test("PermissionRequest ExitPlanMode (voie principale) → plan multi-lignes")
    func planViaPermissionRequest() {
        // Chemin découvert non couvert : plan avec markdown multi-lignes (\n échappé).
        let env = envelope(event: [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/p",
            "tool_name": "ExitPlanMode",
            "tool_input": [
                "plan": "# Refactor the auth flow\n\n1. Extract token logic\n2. Add refresh",
                "allowedPrompts": [["tool": "Bash", "prompt": "npm test"]],
            ],
        ])
        guard case .decision(let prompt) = ClaudeEventRouter.route(env, now: Date()),
              case .plan(let plan) = prompt.payload else { Issue.record("attendu plan"); return }
        #expect(plan.title == "Refactor the auth flow")
        #expect(plan.viaPreToolUse == false) // voie PermissionRequest
        #expect(plan.markdown.contains("Extract token logic"))
        #expect(plan.allowedPrompts == ["Bash: npm test"])
    }

    @Test("PreToolUse AskUserQuestion → prompt question actionnable")
    func questionPrompt() {
        let env = envelope(event: [
            "hook_event_name": "PreToolUse", "session_id": "s1", "cwd": "/p",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "Which?", "header": "Pick", "multiSelect": false,
                "options": [["label": "A"], ["label": "B"]],
            ]]],
        ])
        guard case .decision(let prompt) = ClaudeEventRouter.route(env, now: Date()),
              case .question(let q) = prompt.payload else { Issue.record("attendu question"); return }
        #expect(q.questions.count == 1)
        #expect(q.questions[0].options == ["A", "B"])
        #expect(prompt.capabilities.canAnswerInline)
    }

    @Test("PreToolUse (Bash) et Stop → télémétrie, jamais un prompt")
    func telemetry() {
        for event in [
            ["hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash", "tool_use_id": "t1"],
            ["hook_event_name": "Stop", "session_id": "s1"],
        ] {
            if case .decision = ClaudeEventRouter.route(envelope(event: event), now: Date()) {
                Issue.record("ne doit pas être une décision : \(event)")
            }
        }
    }
}

@Suite("ClaudeHooksInstaller (03 · REQ-CLA-01/02/05)")
struct ClaudeHooksInstallerTests {
    /// Prépare un ~/.claude sandboxé avec un settings.json existant portant un hook tiers.
    private func sandbox(existing: [String: Any]?) throws -> DashPaths {
        let paths = try SandboxHome.create()
        try FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
        // le binaire hook doit exister pour le statut « ready »
        try FileManager.default.createDirectory(at: paths.hookBinaryDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.hookBinary.path, contents: Data("#!/bin/sh\n".utf8))
        if let existing {
            let data = try JSONSerialization.data(withJSONObject: existing)
            try data.write(to: paths.claudeSettings)
        }
        return paths
    }

    @Test("installation : préserve les hooks tiers et le reste des settings")
    func preservesThirdParty() async throws {
        let thirdParty: [String: Any] = [
            "permissions": ["allow": ["WebSearch"]],
            "hooks": ["PreToolUse": [[
                "matcher": "Bash",
                "hooks": [["type": "command", "command": "/usr/local/bin/other-hook"]],
            ]]],
        ]
        let paths = try sandbox(existing: thirdParty)
        let installer = ClaudeHooksInstaller(paths: paths)
        try await installer.installOrRepair()

        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
        // permissions intactes
        #expect((settings["permissions"] as? [String: Any])?["allow"] as? [String] == ["WebSearch"])
        // hook tiers toujours là
        let preToolUse = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        let commands = preToolUse.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        #expect(commands.contains { $0.contains("other-hook") })
        #expect(commands.contains { $0.contains("agentdash-hook") })
        // statut ready
        #expect(await installer.status() == .ready)
    }

    @Test("idempotence : une 2e installation ne duplique pas nos entrées")
    func idempotent() async throws {
        let paths = try sandbox(existing: nil)
        let installer = ClaudeHooksInstaller(paths: paths)
        try await installer.installOrRepair()
        try await installer.installOrRepair()
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
        let perm = (settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        let ours = perm.filter { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("agentdash-hook") == true }
        }
        #expect(ours.count == 1)
    }

    @Test("désinstallation : retire nos entrées, restaure l'état d'origine")
    func uninstallRestores() async throws {
        let paths = try sandbox(existing: ["permissions": ["allow": ["WebSearch"]]])
        let installer = ClaudeHooksInstaller(paths: paths)
        try await installer.installOrRepair()
        try await installer.uninstall()
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeSettings)) as! [String: Any]
        #expect(settings["hooks"] == nil) // aucune entrée résiduelle → clé retirée
        #expect((settings["permissions"] as? [String: Any])?["allow"] as? [String] == ["WebSearch"])
    }

    @Test("agent non détecté : aucune écriture")
    func notDetected() async throws {
        let paths = try SandboxHome.create() // pas de ~/.claude
        let installer = ClaudeHooksInstaller(paths: paths)
        #expect(await installer.status() == .agentNotDetected)
        await #expect(throws: (any Error).self) { try await installer.installOrRepair() }
    }
}
