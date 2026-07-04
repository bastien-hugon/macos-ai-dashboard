import DashCore
import SwiftUI

/// Section repliable du panel, conventions SwiftUI DisclosureGroup : header entièrement
/// cliquable, chevron qui pivote (droite → bas), animation spring interruptible, état
/// persisté par l'appelant (Binding), badge de compte visible replié, hover feedback,
/// accessibilité (bouton + valeur expanded/collapsed).
public struct NotchDisclosureSection<Content: View>: View {
    let title: String
    let badge: String?
    @Binding var isExpanded: Bool
    let settings: SettingsStore
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        badge: String? = nil,
        isExpanded: Binding<Bool>,
        settings: SettingsStore,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.badge = badge
        self._isExpanded = isExpanded
        self.settings = settings
        self.content = content
    }

    public var body: some View {
        let metrics = DensityMetrics.metrics(for: settings.density, titleWeight: settings.titleWeight)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                              : .spring(response: 0.32, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(metrics.titleFont)
                        .foregroundStyle(.white.opacity(isHovering ? 0.7 : 0.45))
                        .textCase(.uppercase)
                    if let badge, !isExpanded {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .transition(.opacity)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(isHovering ? 0.7 : 0.4))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle()) // toute la ligne est cliquable
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed\(badge.map { ", \($0) items" } ?? "")")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double-tap to \(isExpanded ? "collapse" : "expand")")

            if isExpanded {
                content()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .clipped() // le contenu glisse sous le header sans déborder de la section
    }
}
