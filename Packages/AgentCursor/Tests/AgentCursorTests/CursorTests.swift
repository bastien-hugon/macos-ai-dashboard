import DashCore
import Foundation
import Testing
import TestSupport
@testable import AgentCursor

@Suite("CursorStateReader.parseComposers (04 · §2.3)")
struct ParseComposersTests {
    private func data(_ composers: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["allComposers": composers])
    }

    @Test("session normale : titre, projet, diff, activité, état")
    func normal() {
        let sessions = CursorStateReader.parseComposers(data([[
            "composerId": "c1", "type": "head", "name": "Refactor router",
            "createdAt": 1_780_000_000_000, "lastUpdatedAt": 1_780_000_100_000,
            "totalLinesAdded": 120, "totalLinesRemoved": 30, "filesChangedCount": 4,
            "subtitle": "Edited package.json",
            "workspaceIdentifier": ["uri": ["fsPath": "/Users/x/proj"]],
        ]]))
        #expect(sessions.count == 1)
        let s = sessions[0]
        #expect(s.id.agent == .cursor)
        #expect(s.title == "Refactor router")
        #expect(s.projectPath == "/Users/x/proj")
        #expect(s.diff == DiffStats(added: 120, removed: 30))
        #expect(s.filesTouched == 4)
        #expect(s.lastActivity == "Edited package.json")
        #expect(s.host == .ide("Cursor"))
    }

    @Test("hasBlockingPendingActions / hasPendingPlan → waiting")
    func waiting() {
        let blocking = CursorStateReader.parseComposers(data([[
            "composerId": "c2", "name": "x", "hasBlockingPendingActions": true,
        ]]))
        #expect(blocking.first?.state == .waiting)
        let plan = CursorStateReader.parseComposers(data([[
            "composerId": "c3", "name": "y", "hasPendingPlan": true,
        ]]))
        #expect(plan.first?.state == .waiting)
    }

    @Test("filtres : brouillon, archivé, best-of-N, subagent exclus")
    func filters() {
        let sessions = CursorStateReader.parseComposers(data([
            ["composerId": "keep", "name": "keep"],
            ["composerId": "draft", "isDraft": true],
            ["composerId": "archived", "isArchived": true],
            ["composerId": "bestof", "isBestOfNSubcomposer": true],
            ["composerId": "subagent", "subagentInfo": ["subagentType": 1]],
        ]))
        #expect(sessions.map(\.id.nativeID) == ["keep"])
    }
}

@Suite("CursorHooksInstaller (04 · REQ-CUR)")
struct CursorHooksInstallerTests {
    private func sandbox() throws -> DashPaths {
        let paths = try SandboxHome.create()
        try FileManager.default.createDirectory(at: paths.cursorDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.hookBinaryDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.hookBinary.path, contents: Data("#!/bin/sh\n".utf8))
        return paths
    }

    @Test("crée hooks.json (version 1) quand il n'existe pas, statut Ready")
    func createsFromScratch() async throws {
        let paths = try sandbox()
        let installer = CursorHooksInstaller(paths: paths)
        #expect(await installer.status() == .notInstalled)
        try await installer.installOrRepair()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.cursorHooks)) as! [String: Any]
        #expect(config["version"] as? Int == 1)
        let hooks = config["hooks"] as? [String: Any]
        let shell = hooks?["beforeShellExecution"] as? [[String: Any]]
        #expect(shell?.first?["command"] as? String != nil)
        #expect(await installer.status() == .ready)
    }

    @Test("fusion : préserve un hook tiers existant")
    func preservesThirdParty() async throws {
        let paths = try sandbox()
        let existing: [String: Any] = [
            "version": 1,
            "hooks": ["beforeShellExecution": [["command": "/opt/other-hook"]]],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: paths.cursorHooks)
        try await CursorHooksInstaller(paths: paths).installOrRepair()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.cursorHooks)) as! [String: Any]
        let shell = (config["hooks"] as? [String: Any])?["beforeShellExecution"] as? [[String: Any]] ?? []
        let commands = shell.compactMap { $0["command"] as? String }
        #expect(commands.contains { $0.contains("other-hook") })
        #expect(commands.contains { $0.contains("agentdash-hook") })
    }

    @Test("idempotence + désinstallation propre")
    func idempotentAndUninstall() async throws {
        let paths = try sandbox()
        let installer = CursorHooksInstaller(paths: paths)
        try await installer.installOrRepair()
        try await installer.installOrRepair()
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.cursorHooks)) as! [String: Any]
        let shell = (config["hooks"] as? [String: Any])?["beforeShellExecution"] as? [[String: Any]] ?? []
        #expect(shell.filter { ($0["command"] as? String)?.contains("agentdash-hook") == true }.count == 1)
        try await installer.uninstall()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.cursorHooks)) as! [String: Any]
        #expect(after["hooks"] == nil)
    }
}

@Suite("CursorTimelineReader — normalisation des outils (M13, research §2.5)")
struct CursorTimelineTests {
    @Test("noms d'outils internes → langage clair")
    func toolNames() {
        #expect(CursorTimelineReader.summarize(toolName: "run_terminal_command_v2", params: nil, status: "completed") == "Ran a command")
        #expect(CursorTimelineReader.summarize(toolName: "edit_file_v2", params: #"{"target_file":"/p/Auth.swift"}"#, status: "completed") == "Edited Auth.swift")
        #expect(CursorTimelineReader.summarize(toolName: "read_file_v2", params: #"{"target_file":"/p/Main.swift"}"#, status: "completed") == "Read Main.swift")
        #expect(CursorTimelineReader.summarize(toolName: "ripgrep_raw_search", params: nil, status: "completed") == "Searched files")
        #expect(CursorTimelineReader.summarize(toolName: "task_v2", params: nil, status: "completed") == "Launched a subagent")
        #expect(CursorTimelineReader.summarize(toolName: "mcp-memory-store", params: nil, status: "completed") == "Ran an MCP tool")
    }

    @Test("statut loading → indicateur (running)")
    func loadingStatus() {
        #expect(CursorTimelineReader.summarize(toolName: "edit_file_v2", params: nil, status: "loading").contains("(running)"))
    }
}

@Suite("CursorEventRouter (08 · REQ-ACT-23)")
struct CursorEventRouterTests {
    private func envelope(_ event: [String: Any]) -> HookEnvelope {
        let json = String(data: try! JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
        return HookEnvelope(id: "1", source: "cursor", termProgram: nil, ppid: 1, eventJSON: json)
    }

    @Test("beforeShellExecution → prompt permission (sans always-allow)")
    func shellPermission() {
        let routing = CursorEventRouter.route(envelope([
            "hook_event_name": "beforeShellExecution",
            "conversation_id": "conv1",
            "command": "rm -rf dist",
            "workspace_roots": ["/Users/x/proj"],
        ]), now: Date())
        guard case .decision(let prompt) = routing,
              case .permission(let request) = prompt.payload else {
            Issue.record("attendu une décision permission"); return
        }
        #expect(prompt.sessionID == SessionID(agent: .cursor, nativeID: "conv1"))
        #expect(request.commandText == "rm -rf dist")
        #expect(request.honestEffects.contains { $0.contains("Deletes") })
        #expect(prompt.capabilities.canAlwaysAllow == false) // limite Cursor
        #expect(prompt.capabilities.canDenyWithFeedback)
    }

    @Test("stop → télémétrie, pas un prompt")
    func stopTelemetry() {
        if case .decision = CursorEventRouter.route(envelope([
            "hook_event_name": "stop", "conversation_id": "conv1",
        ]), now: Date()) {
            Issue.record("stop ne doit pas être une décision")
        }
    }
}
