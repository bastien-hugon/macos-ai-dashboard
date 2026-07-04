import Foundation

/// Analyse « honnête » d'une commande shell (08 · §3.4, REQ-ACT-14/15) : détecte les
/// effets d'écriture à partir de la commande **elle-même** (jamais du seul `description`
/// fourni par le modèle). Heuristique assumée — jamais présentée comme une preuve ;
/// les constructions opaques désactivent l'analyse.
public enum CommandAnalysis: Equatable, Sendable {
    case effects([String])          // libellés d'effets ; vide = lecture seule apparente
    case opaque(reason: String)     // eval, $(…), pipe vers sh… → « Effects unclear »
}

public enum HonestCommandAnalyzer {
    private static let opaqueMarkers = ["`", "$(", "eval ", "xargs", "-exec"]
    private static let shellRunners: Set<String> = ["sh", "bash", "zsh", "fish"]

    public static func analyze(_ command: String) -> CommandAnalysis {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .effects([]) }

        // 1. Opacité globale : substitutions, eval, xargs, find -exec.
        for marker in opaqueMarkers where trimmed.contains(marker) {
            return .opaque(reason: "Effects unclear — review the command")
        }

        var effects: [String] = []
        // 2. Découpage en commandes simples.
        let separators = CharacterSet(charactersIn: "\n")
        let byLine = trimmed.components(separatedBy: separators)
        for rawLine in byLine {
            for segment in splitOperators(rawLine) {
                let tokens = tokenize(segment)
                guard !tokens.isEmpty else { continue }
                let stripped = stripPrefixes(tokens)
                guard let head = stripped.first else { continue }
                // Un shell comme commande (pipe vers sh, `bash -c`, exécution de script) →
                // effets indéterminables (REQ-ACT-15).
                if shellRunners.contains((head as NSString).lastPathComponent) {
                    return .opaque(reason: "Effects unclear — review the command")
                }
                if let effect = effect(of: head, args: Array(stripped.dropFirst())) {
                    effects.append(effect)
                }
                // Redirections vers fichier (> / >>).
                if let target = redirectionTarget(in: segment) {
                    effects.append("Writes to \(target)")
                }
            }
        }
        return .effects(dedupe(effects))
    }

    // MARK: -

    private static func effect(of command: String, args: [String]) -> String? {
        let firstFile = args.first { !$0.hasPrefix("-") }
        switch command {
        case "rm": return "Deletes \(firstFile ?? "files")"
        case "mv": return "Moves \(firstFile ?? "files")"
        case "cp": return "Copies \(firstFile.map { "to \($0)" } ?? "files")"
        case "mkdir": return "Creates \(firstFile ?? "a directory")"
        case "touch": return "Creates \(firstFile ?? "a file")"
        case "tee": return "Writes to \(firstFile ?? "a file")"
        case "chmod", "chown": return "Changes permissions on \(firstFile ?? "files")"
        case "dd": return "Writes raw data"
        case "git":
            let sub = args.first { !$0.hasPrefix("-") }
            switch sub {
            case "push": return "Pushes to a remote"
            case "reset": return args.contains("--hard") ? "Discards local changes (git reset --hard)" : nil
            case "clean": return "Deletes untracked files (git clean)"
            case "checkout", "restore": return "Overwrites working tree files"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Cible d'une redirection `>`/`>>` (hors `2>&1`, `>/dev/null`).
    private static func redirectionTarget(in segment: String) -> String? {
        let tokens = tokenize(segment)
        for (i, token) in tokens.enumerated() where token == ">" || token == ">>" {
            if let next = tokens[safe: i + 1], next != "/dev/null" { return next }
        }
        // Formes collées : `foo>bar`.
        if let range = segment.range(of: #"[^\s]>>?\s*[^\s&|]+"#, options: .regularExpression) {
            let piece = segment[range]
            if let target = piece.split(whereSeparator: { $0 == ">" }).last?
                .trimmingCharacters(in: .whitespaces), target != "/dev/null", !target.isEmpty {
                return target
            }
        }
        return nil
    }

    private static func splitOperators(_ line: String) -> [String] {
        line.components(separatedBy: CharacterSet(charactersIn: ";&|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func stripPrefixes(_ tokens: [String]) -> [String] {
        var result = tokens
        let prefixes: Set<String> = ["env", "sudo", "nohup", "time", "nice"]
        while let first = result.first, prefixes.contains(first) || first.contains("=") {
            result.removeFirst()
        }
        return result
    }

    /// Tokenisation respectant guillemets simples/doubles (pas un vrai parseur sh).
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for char in input {
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == " " || char == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
