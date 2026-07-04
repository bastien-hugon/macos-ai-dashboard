import DashCore
import SwiftUI

/// Liste des sessions groupées par projet (07 · REQ-SES-02..04) — contenu de la
/// section « Sessions » du panel, injectée par la composition root.
public struct SessionListView: View {
    let store: SessionStore
    let settings: SettingsStore
    let onKill: (Session) -> Void
    let onCopyMarkdown: (Session) -> Void
    let onDismiss: (Session) -> Void
    let onOpenTerminal: (Session) -> Void

    @State private var expandedID: SessionID?

    public init(store: SessionStore, settings: SettingsStore,
                onKill: @escaping (Session) -> Void = { _ in },
                onCopyMarkdown: @escaping (Session) -> Void = { _ in },
                onDismiss: @escaping (Session) -> Void = { _ in },
                onOpenTerminal: @escaping (Session) -> Void = { _ in }) {
        self.store = store
        self.settings = settings
        self.onKill = onKill
        self.onCopyMarkdown = onCopyMarkdown
        self.onDismiss = onDismiss
        self.onOpenTerminal = onOpenTerminal
    }

    /// Hauteur max de la liste avant scroll interne (07 · REQ-NUI-34 `.fixed`) : évite que
    /// beaucoup de sessions poussent usage/serveurs/routes hors du panel. Réserve toujours de
    /// la place aux sections suivantes.
    private var listMaxHeight: CGFloat? {
        settings.sessionListSizing == .fixed ? 210 : nil
    }

    public var body: some View {
        let metrics = DensityMetrics.metrics(for: settings.density, titleWeight: settings.titleWeight)
        let content = VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            ForEach(store.groups) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.leading, 2)
                    ForEach(group.sessions) { session in
                        SessionCardView(
                            session: session,
                            metrics: metrics,
                            settings: settings,
                            isExpanded: expandedID == session.id
                        )
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expandedID = expandedID == session.id ? nil : session.id
                            }
                        }
                        .contextMenu {
                            Button("Copy Session as Markdown") { onCopyMarkdown(session) }
                            Button("Open Terminal") { onOpenTerminal(session) }
                            if session.pid != nil, session.liveness.isLive {
                                Divider()
                                Button("Kill Session", role: .destructive) { onKill(session) }
                            }
                            if !session.liveness.isLive {
                                Button("Dismiss") { onDismiss(session) }
                            }
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.groups.map(\.id))

        if let listMaxHeight {
            ScrollView { content }.frame(maxHeight: listMaxHeight)
        } else {
            content
        }
    }
}

/// Carte de session (07 · REQ-SES-17..29) : avatar animé, identité, activité récente,
/// chips (tokens, diff, compteurs, host), temps écoulé. Tap → row étendue.
struct SessionCardView: View {
    let session: Session
    let metrics: DensityMetrics
    let settings: SettingsStore
    let isExpanded: Bool

    private var dimmed: Bool { !session.liveness.isLive }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded { expandedContent }
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isExpanded ? 0.07 : 0.045))
        )
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Ligne principale

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            PixelAvatarView(
                seed: session.avatarSeed,
                state: session.state,
                paused: dimmed || session.state == .idle, // REQ-NUI-54
                sideLength: metrics.avatarSide,
                framesPerSecond: 12 // fluide sans surcoût (cartes visibles seulement panel ouvert)
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(session.state.tint)
                        .frame(width: 6, height: 6) // pastille d'état (07 · §4)
                    Text(session.id.agent.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(session.displayTitle)
                        .font(metrics.titleFont)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                if let activity = session.lastActivity {
                    Text(activity)
                        .font(metrics.bodyFont)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1) // REQ-SES-20
                }
                chips
            }
            Spacer(minLength: 4)
            trailing
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if !session.tokens.isEmpty {
                chip(DashFormat.tokenChip(session.tokens)) // « 24.6k / 66 » REQ-SES-21
            }
            if !session.diff.isEmpty {
                HStack(spacing: 3) {
                    Text("+\(session.diff.added)").foregroundStyle(.green.opacity(0.85))
                    Text("−\(session.diff.removed)").foregroundStyle(.red.opacity(0.8))
                }
                .font(metrics.metricFont)
            }
            if session.filesTouched > 0 || session.commandCount > 0 {
                chip("\(session.filesTouched) files · \(session.commandCount) cmds") // REQ-SES-24
            }
            chip(session.host.label)
            if session.subagentCount > 0 {
                chip("\(session.subagentCount) subagent\(session.subagentCount > 1 ? "s" : "")")
            }
        }
        .opacity(settings.metricsOpacity)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(metrics.metricFont)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if case .ended(let reason) = session.liveness {
                Text(reason.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ElapsedText(since: session.startedAt) // REQ-SES-27
                    .font(metrics.metricFont)
                    .foregroundStyle(.white.opacity(settings.metricsOpacity * 0.7))
            }
        }
    }

    // MARK: - Row étendue (07 · REQ-SES-30..36, version M1)

    @ViewBuilder private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let excerpt = session.lastReplyExcerpt {
                ReplyExcerptView(markdown: excerpt, font: metrics.bodyFont)
            }
            if !session.timeline.isEmpty {
                Divider().overlay(Color.white.opacity(0.1))
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(session.timeline.suffix(30).reversed()) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.3))
                            Text(event.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.leading, metrics.avatarSide + 10)
    }
}

/// Extrait de la dernière réponse, rendu Markdown natif + repli (03 · REQ-CLA-26).
struct ReplyExcerptView: View {
    let markdown: String
    let font: Font
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attributed)
                .font(font)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(showMore ? nil : 4)
                .textSelection(.enabled)
            if markdown.count > 280 {
                Button(showMore ? "Show less" : "Show more") {
                    withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// Temps écoulé, mis à jour à la seconde (timer actif uniquement quand la vue existe,
/// donc panel ouvert — 07 · REQ-SES-27).
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(DashFormat.elapsed(context.date.timeIntervalSince(since)))
        }
    }
}
