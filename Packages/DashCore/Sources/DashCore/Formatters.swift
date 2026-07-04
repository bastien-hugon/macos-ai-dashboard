import Foundation

/// Formats d'affichage tranchés produit (07 · REQ-SES-22/27).
public enum DashFormat {
    /// Format numérique des tokens (07 · REQ-SES-22) :
    /// 0–999 → « 66 » ; 1 000–99 949 → « 24.6k » (décimale supprimée si nulle) ;
    /// 99 950–999 499 → « 245k » ; ≥ 999 500 → « 1.2M ».
    public static func tokens(_ value: Int) -> String {
        precondition(value >= 0)
        switch value {
        case 0..<1000:
            return "\(value)"
        case 1000..<99_950:
            let tenths = (value * 10 + 500) / 1000 // arrondi au plus proche, en dixièmes de k
            if tenths % 10 == 0 { return "\(tenths / 10)k" }
            return "\(tenths / 10).\(tenths % 10)k"
        case 99_950..<999_500:
            return "\((value + 500) / 1000)k"
        default:
            let tenths = (value + 50_000) / 100_000
            if tenths % 10 == 0 { return "\(tenths / 10)M" }
            return "\(tenths / 10).\(tenths % 10)M"
        }
    }

    /// Chip tokens « input / output » (07 · REQ-SES-21) : input = `input_tokens` seul.
    public static func tokenChip(_ tally: TokenTally) -> String {
        "\(tokens(tally.inputTokens)) / \(tokens(tally.outputTokens))"
    }

    /// Temps écoulé (07 · REQ-SES-27) : « 42s », « 7m », « 1h 24m », « 2d 3h ».
    public static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        switch seconds {
        case 0..<60:
            return "\(seconds)s"
        case 60..<3600:
            return "\(seconds / 60)m"
        case 3600..<86_400:
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        default:
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3600
            return "\(days)d \(hours)h"
        }
    }
}
