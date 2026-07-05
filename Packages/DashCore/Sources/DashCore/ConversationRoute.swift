import Foundation

/// Route d'ouverture d'une conversation dans son app hôte (bouton « Open », REQ-ACT-23).
///
/// Mécanismes (vérifiés le 5 juil. 2026 sur Cursor 3.8.11 + extension claude-code 2.1.201) :
/// - **Claude Code hébergé en IDE** : l'extension `anthropic.claude-code` enregistre un
///   handler URI `…://anthropic.claude-code/open?session=<id>` qui exécute
///   `claude-vscode.primaryEditor.open(session)` → ouvre/focus la conversation.
///   Schéma = `cursor://` dans Cursor, `vscode://` dans VS Code.
/// - **Cursor (composers locaux)** : PAS de deep-link public par composerId (le handler
///   `anysphere.cursor-deeplink` n'adresse que les agents cloud via `bcId`). On focus donc
///   la fenêtre du workspace (ouvrir le dossier réutilise la fenêtre existante) : les
///   sessions affichées étant actives, leur conversation y est celle sélectionnée.
/// - **Claude Code en terminal** : pas de route (la conversation vit dans le terminal).
public enum ConversationRoute: Equatable, Sendable {
    /// Ouvrir le dossier dans l'app hôte (focus la fenêtre existante du workspace),
    /// puis éventuellement suivre d'un deep-link (posé dans la fenêtre focusée).
    case focusWorkspace(appName: String, folder: String, thenOpen: URL?)
    /// Ouvrir directement un deep-link.
    case deepLink(URL)
    /// Activer simplement l'app hôte (aucune information de workspace).
    case activate(appName: String)

    /// Route d'ouverture pour une session, `nil` si la conversation n'est pas adressable
    /// (Claude en terminal / desktop / hôte inconnu).
    public static func route(for session: Session) -> ConversationRoute? {
        switch session.id.agent {
        case .cursor:
            if let folder = session.projectPath, !folder.isEmpty {
                return .focusWorkspace(appName: "Cursor", folder: folder, thenOpen: nil)
            }
            return .activate(appName: "Cursor")
        case .claude:
            guard case .ide(let app) = session.host else { return nil }
            guard let url = claudeExtensionURL(sessionID: session.id.nativeID, ideName: app) else { return nil }
            // « IDE » = ancêtre irrésolu (HostResolver) : pas de nom d'app lançable →
            // deep-link direct (le schéma cursor:// route vers la bonne app de toute façon).
            if let folder = session.projectPath, !folder.isEmpty, app != "IDE" {
                return .focusWorkspace(appName: app, folder: folder, thenOpen: url)
            }
            return .deepLink(url)
        }
    }

    /// Deep-link du handler URI de l'extension Claude Code (`/open?session=…`).
    public static func claudeExtensionURL(sessionID: String, ideName: String) -> URL? {
        // Cursor → cursor:// ; VS Code (« Visual Studio Code », « Code ») → vscode:// ;
        // IDE inconnu → cursor:// (environnement cible du produit).
        let scheme = ideName.localizedCaseInsensitiveContains("code") ? "vscode" : "cursor"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-") // UUIDs ; tout le reste est percent-encodé (défensif)
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "\(scheme)://anthropic.claude-code/open?session=\(encoded)")
    }
}
