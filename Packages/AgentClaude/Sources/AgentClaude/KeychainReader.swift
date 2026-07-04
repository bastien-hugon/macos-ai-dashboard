import DashCore
import Foundation
import Security

/// Lecture des credentials OAuth de Claude Code dans le Keychain macOS
/// (research claude-code §4.1) : item generic password, service « Claude Code-credentials ».
/// La lecture déclenche une invite d'autorisation Keychain la première fois (UX onboarding).
/// AgentDash ne rafraîchit JAMAIS le token lui-même : Claude Code s'en charge, on relit.
enum KeychainReader {
    struct ClaudeCredentials: Sendable {
        var accessToken: String
        var expiresAt: Date?
        var accountLabel: String?  // email / organisation si présents [HYPOTHÈSE claude-code n°5]
    }

    static func claudeCredentials() throws -> ClaudeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecItemNotFound { throw UsageError.accountUnavailable }
            throw UsageError.accountUnavailable // invite déclinée / accès refusé
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw UsageError.decoding(field: "claudeAiOauth.accessToken")
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        let label = (oauth["account"] as? [String: Any])?["email_address"] as? String
            ?? oauth["email"] as? String
            ?? (oauth["organization"] as? [String: Any])?["name"] as? String
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt, accountLabel: label)
    }
}

/// Détection de la version du CLI Claude Code — nécessaire pour le header `User-Agent`
/// (sans lui : 429 persistants, research claude-code §4.1).
enum ClaudeVersion {
    /// Cherche la version dans les transcripts récents ou le registre de sessions, sinon défaut.
    static func detect(paths: DashPaths) -> String {
        // Le registre ~/.claude/sessions/<pid>.json porte le champ "version".
        if let files = try? FileManager.default.contentsOfDirectory(at: paths.claudeSessionsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = dict["version"] as? String {
                    return version
                }
            }
        }
        return "2.1.199" // défaut raisonnable [HYPOTHÈSE — actualisé si détecté]
    }
}
