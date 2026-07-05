import DashCore
import Foundation
import Testing

@Suite("ConversationRoute — bouton Open (REQ-ACT-23)")
struct ConversationRouteTests {
    private func session(agent: AgentKind, id: String = "b5ab8fa7-f9ba-4c13-82a0-41e621f131c5",
                         host: SessionHost, projectPath: String? = "/tmp/proj") -> Session {
        Session(id: SessionID(agent: agent, nativeID: id), state: .executing,
                liveness: .live, title: "t", projectPath: projectPath,
                startedAt: Date(timeIntervalSince1970: 1000), host: host)
    }

    @Test("Cursor avec projectPath → focus de la fenêtre du workspace, sans deep-link")
    func cursorFocusesWorkspace() {
        let route = ConversationRoute.route(for: session(agent: .cursor, host: .ide("Cursor")))
        #expect(route == .focusWorkspace(appName: "Cursor", folder: "/tmp/proj", thenOpen: nil))
    }

    @Test("Cursor sans projectPath → activation simple de l'app")
    func cursorWithoutPathActivates() {
        let route = ConversationRoute.route(for: session(agent: .cursor, host: .ide("Cursor"), projectPath: nil))
        #expect(route == .activate(appName: "Cursor"))
    }

    @Test("Claude dans Cursor → focus workspace puis deep-link cursor://anthropic.claude-code/open")
    func claudeInCursor() {
        let route = ConversationRoute.route(for: session(agent: .claude, host: .ide("Cursor")))
        let expected = URL(string: "cursor://anthropic.claude-code/open?session=b5ab8fa7-f9ba-4c13-82a0-41e621f131c5")!
        #expect(route == .focusWorkspace(appName: "Cursor", folder: "/tmp/proj", thenOpen: expected))
    }

    @Test("Claude dans VS Code → schéma vscode://")
    func claudeInVSCode() {
        let route = ConversationRoute.route(for: session(agent: .claude, host: .ide("VS Code"), projectPath: nil))
        #expect(route == .deepLink(URL(string: "vscode://anthropic.claude-code/open?session=b5ab8fa7-f9ba-4c13-82a0-41e621f131c5")!))
    }

    @Test("Claude hôte IDE irrésolu → deep-link direct (pas d'open -a « IDE »)")
    func claudeUnknownIDE() {
        let route = ConversationRoute.route(for: session(agent: .claude, host: .ide("IDE")))
        #expect(route == .deepLink(URL(string: "cursor://anthropic.claude-code/open?session=b5ab8fa7-f9ba-4c13-82a0-41e621f131c5")!))
    }

    @Test("Claude en terminal ou desktop → aucune route (pas de bouton)")
    func claudeTerminalHasNoRoute() {
        #expect(ConversationRoute.route(for: session(agent: .claude, host: .terminal("iTerm"))) == nil)
        #expect(ConversationRoute.route(for: session(agent: .claude, host: .desktopApp)) == nil)
        #expect(ConversationRoute.route(for: session(agent: .claude, host: .unknown)) == nil)
    }

    @Test("sessionId exotique → percent-encodé dans le deep-link")
    func sessionIDIsEncoded() {
        let url = ConversationRoute.claudeExtensionURL(sessionID: "a b&c", ideName: "Cursor")
        #expect(url?.absoluteString == "cursor://anthropic.claude-code/open?session=a%20b%26c")
    }
}
