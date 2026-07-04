import SwiftUI

/// Bouton de décision stylé (Allow/Deny/…), avec libellé de raccourci optionnel.
struct PromptButton: View {
    enum Kind { case primary, normal }
    let title: String
    let shortcut: String?
    let kind: Kind
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let shortcut {
                    Text(shortcut).font(.system(size: 10, weight: .medium)).opacity(0.7)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(kind == .primary ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.10))
            )
            .foregroundStyle(kind == .primary ? .white : .white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// Layout à retour à la ligne pour les pilules d'options (macOS 14 — pas de FlowLayout natif).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([]); x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let height = rows.reduce(0) { $0 + (($1.map(\.height).max() ?? 0)) } + CGFloat(rows.count - 1) * spacing
        return CGSize(width: maxWidth == .infinity ? (rows.first?.reduce(0) { $0 + $1.width } ?? 0) : maxWidth, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
