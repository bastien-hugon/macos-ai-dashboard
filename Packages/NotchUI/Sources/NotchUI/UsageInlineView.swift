import DashCore
import SwiftUI

/// Logomark Anthropic simplifié (« A » angulaire), tracé vectoriel monochrome.
struct AnthropicMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        // « Λ » épais : apex plat, jambes larges, creux central.
        p.move(to: pt(0.00, 1.00))
        p.addLine(to: pt(0.38, 0.00))
        p.addLine(to: pt(0.62, 0.00))
        p.addLine(to: pt(1.00, 1.00))
        p.addLine(to: pt(0.76, 1.00))
        p.addLine(to: pt(0.50, 0.32))
        p.addLine(to: pt(0.24, 1.00))
        p.closeSubpath()
        return p
    }
}

/// Logomark Cursor simplifié (cube isométrique : hexagone + arêtes en Y).
struct CursorMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        // Hexagone pointe en haut (angles 90°, 150°, … 30°).
        let angles: [CGFloat] = [90, 150, 210, 270, 330, 30]
        let points = angles.map { a -> CGPoint in
            let rad = a * .pi / 180
            return CGPoint(x: c.x + r * cos(rad), y: c.y - r * sin(rad))
        }
        p.move(to: points[0])
        for pt in points.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        // Arêtes internes du cube (Y) : centre → sommets 30°, 150°, 270°.
        for i in [5, 1, 3] {
            p.move(to: c)
            p.addLine(to: points[i])
        }
        return p
    }
}

/// Ligne d'usage inline, centrée en haut du panel :
/// [Anthropic] (% session) (tokens du jour) · [Cursor] ($ du jour) (tokens du jour).
public struct UsageInlineView: View {
    let usage: UsageStore
    let settings: SettingsStore

    public init(usage: UsageStore, settings: SettingsStore) {
        self.usage = usage
        self.settings = settings
    }

    public var body: some View {
        HStack(spacing: 20) {
            claudeGroup
            cursorGroup
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .opacity(settings.metricsOpacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Claude : [logo] (% session) (tokens du jour)

    @ViewBuilder private var claudeGroup: some View {
        let gauge = usage.hasAnyClaudeWindow ? usage.gauge(for: .fiveHour) : nil
        let today = usage.today[.claude]
        if gauge != nil || today != nil {
            HStack(spacing: 6) {
                AnthropicMark()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 11, height: 11)
                if let gauge, let _ = gauge.fillFraction {
                    Text(gauge.percentText)
                        .foregroundStyle(gauge.color.swiftUIColor)
                } else {
                    Text("--").foregroundStyle(.white.opacity(0.4))
                }
                Text(DashFormat.tokens(today?.tokens ?? 0))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .help("Claude Code — 5-hour session usage · tokens today")
        }
    }

    // MARK: - Cursor : [logo] ($ du jour) (tokens du jour)

    @ViewBuilder private var cursorGroup: some View {
        if let today = usage.today[.cursor] {
            HStack(spacing: 6) {
                CursorMark()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.1)
                    .frame(width: 11, height: 11)
                Text(UsageFormat.dollars(today.costUSD ?? 0))
                    .foregroundStyle(.white.opacity(0.9))
                Text(DashFormat.tokens(today.tokens))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .help("Cursor — spend today · tokens today")
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let gauge = usage.gauge(for: .fiveHour), usage.hasAnyClaudeWindow {
            parts.append("Claude session \(gauge.percentText), \(DashFormat.tokens(usage.today[.claude]?.tokens ?? 0)) tokens today")
        }
        if let cursor = usage.today[.cursor] {
            parts.append("Cursor \(UsageFormat.dollars(cursor.costUSD ?? 0)) and \(DashFormat.tokens(cursor.tokens)) tokens today")
        }
        return parts.isEmpty ? "No usage data" : parts.joined(separator: ". ")
    }
}
