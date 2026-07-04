import DashCore
import SwiftUI

/// Vue racine d'une surface notch : rend le pill (fermé) ou le panel (ouvert) avec la
/// morphose `NotchShape`, gère le hover à délai d'intention (05 · §3.2) et publie la
/// taille rendue du panel pour le hit-test du clic extérieur.
public struct NotchRootView: View {
    let vm: NotchViewModel
    let coordinator: NotchSurfaceCoordinator
    let sessions: SessionStore
    let prompts: PromptStore
    let usage: UsageStore
    let settings: SettingsStore
    let onRefreshUsage: () -> Void
    let sections: () -> [NotchSection]

    @State private var hoverTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Graine de l'identicon agrégé du pill (constante produit).
    static let pillSeed: UInt64 = 0xA6E1_7DA5

    public init(
        vm: NotchViewModel,
        coordinator: NotchSurfaceCoordinator,
        sessions: SessionStore,
        prompts: PromptStore,
        usage: UsageStore,
        settings: SettingsStore,
        onRefreshUsage: @escaping () -> Void,
        sections: @escaping () -> [NotchSection]
    ) {
        self.vm = vm
        self.coordinator = coordinator
        self.sessions = sessions
        self.prompts = prompts
        self.usage = usage
        self.settings = settings
        self.onRefreshUsage = onRefreshUsage
        self.sections = sections
    }

    public var body: some View {
        VStack(spacing: 0) {
            surface
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onPreferenceChange(PanelSizeKey.self) { [vm] size in
            MainActor.assumeIsolated {
                vm.panelRenderedSize = size
            }
        }
        .onPreferenceChange(PanelHeightKey.self) { [vm] height in
            MainActor.assumeIsolated {
                guard height > 0, abs(vm.panelContentHeight - height) > 0.5 else { return }
                // Croissance du contenu (liste, réponse qui s'étend) : la forme suit en douceur.
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    vm.panelContentHeight = height
                }
            }
        }
    }

    // MARK: - Surface (pill ↔ panel)

    private var expanded: Bool { vm.isExpanded }

    private var shape: NotchShape {
        expanded ? .open : .closed
    }

    /// Vrai morph pill ↔ panel : la taille du conteneur est pilotée explicitement (largeur
    /// ET hauteur animées par le ressort), la forme noire se redimensionne réellement et le
    /// contenu du panel est révélé par le clip pendant la croissance — jamais un simple
    /// crossfade de fenêtre (REQ-NUI-17/46/47).
    private var surface: some View {
        ZStack(alignment: .top) {
            if !expanded {
                pillContent
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
            // Présent pendant opening/panel/closing : sa hauteur naturelle est mesurée
            // pour cibler le resize ; retiré seulement une fois revenu à l'état pill.
            // Reduced Motion : pas de scale, fondu simple (REQ-NUI-51).
            if vm.state != .pill {
                panelContent
                    .frame(width: settings.panelWidth.points)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(panelHeightReader)
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(reduceMotion ? 1 : (expanded ? 1 : 0.94), anchor: .top)
                    .allowsHitTesting(expanded)
            }
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
        .background { backgroundLayer }
        .clipShape(shape)
        .overlay(alignment: .top) {
            // Couture d'anticrénelage avec le bord d'écran (REQ-NUI-24).
            Rectangle().fill(Color.black).frame(height: 1)
        }
        .overlay { rim }
        .overlay(alignment: .top) { notchStripCloseZone }
        .contentShape(shape) // seule zone hit-testable de la fenêtre (REQ-NUI-08)
        .onHover { handleHover($0) }
        .onTapGesture {
            if !expanded { coordinator.open(reason: .click) } // REQ-NUI-19
        }
        // Accessibilité (REQ-NUI-57) : le pill est un élément unique avec label agrégé + action.
        .accessibilityElement(children: expanded ? .contain : .ignore)
        .accessibilityLabel(expanded ? "AgentDash panel" : pillAccessibilityLabel)
        .accessibilityAddTraits(expanded ? [] : .isButton)
        .accessibilityAction(named: expanded ? "Collapse panel" : "Expand panel") {
            if expanded { coordinator.close(reason: .programmatic) }
            else { coordinator.open(reason: .click) }
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius) // REQ-NUI-50
        .background { panelSizeReader }
    }

    /// Taille cible du conteneur, animée par les ressorts d'ouverture/fermeture.
    private var surfaceSize: CGSize {
        if expanded {
            return CGSize(width: settings.panelWidth.points, height: vm.panelContentHeight)
        }
        return CGSize(width: pillWidth, height: pillHeight)
    }

    private var pillWidth: CGFloat {
        let rest = vm.geometry.pillRestSize.width
        if hiddenIdle || settings.pillExpandedOnly { return rest }
        // En mode usage, la largeur est verrouillée sur Wide/Ultra-wide (REQ-USG-36).
        let mode: PillWidthMode = usageModeActive && settings.pillWidthMode == .auto
            ? .wide : settings.pillWidthMode
        return rest + 2 * vm.geometry.wingWidth(mode: mode)
    }

    private var pillHeight: CGFloat {
        vm.geometry.pillRestSize.height + (vm.isHoveringPill && !expanded ? 2 : 0)
    }

    private var hiddenIdle: Bool {
        settings.pillHideWhenIdle && sessions.aggregateState == .idle && !prompts.hasPendingPrompt
    }

    private var shadowOpacity: Double {
        if expanded { return 0.8 }
        return vm.isHoveringPill ? 0.6 : 0
    }

    private var shadowRadius: CGFloat {
        if expanded { return 20 }
        return vm.isHoveringPill ? 14 : 0
    }

    /// Fond : pill = noir pur (REQ-NUI-24) ; panel = verre + voile noir (REQ-NUI-40/45).
    /// Reduce Transparency force le rendu opaque (REQ-NUI-58).
    @ViewBuilder private var backgroundLayer: some View {
        ZStack {
            if expanded && settings.glassOpacity < 1.0 && !reduceTransparency {
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    VisualEffectView()
                }
                Color.black.opacity(settings.glassOpacity)
            } else {
                Color.black
            }
        }
        .clipShape(shape)
    }

    @ViewBuilder private var rim: some View {
        if expanded && settings.frostedRim {
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.25), .white.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            ) // REQ-NUI-41
        }
    }

    /// Clic sur la zone du notch quand le panel est ouvert → fermeture (REQ-NUI-19).
    @ViewBuilder private var notchStripCloseZone: some View {
        if expanded {
            Color.black.opacity(0.001)
                .frame(
                    width: vm.geometry.pillRestSize.width,
                    height: vm.geometry.pillRestSize.height
                )
                .onTapGesture { coordinator.close(reason: .clickNotch) }
        }
    }

    private var panelSizeReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PanelSizeKey.self, value: expanded ? geo.size : .zero)
        }
    }

    /// Mesure la hauteur naturelle du contenu du panel (cible du resize).
    private var panelHeightReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
        }
    }

    // MARK: - Pill

    private var showWings: Bool { !hiddenIdle && !settings.pillExpandedOnly }

    /// Label VoiceOver agrégé du pill (REQ-NUI-57), ex. « AgentDash. 2 sessions running, 1 waiting for permission ».
    private var pillAccessibilityLabel: String {
        AccessibilityLabels.pill(sessions: sessions.displaySessions, hasPrompt: prompts.hasActionablePrompt)
    }

    private var usageModeActive: Bool {
        settings.pillUsageMode && usage.hasAnyClaudeWindow
    }

    private var pillContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if showWings {
                    PixelAvatarView(
                        seed: Self.pillSeed,
                        state: sessions.aggregateState,
                        paused: sessions.liveCount == 0, // REQ-NUI-54 : figé si tout idle
                        sideLength: 14,
                        framesPerSecond: 6 // ≤ 10 fps (spec) ; réduit le coût de rendu panel fermé
                    )
                    .padding(.leading, 12)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            // Découpe physique : rien d'important n'y est dessiné (LED caméra, REQ-NUI-30).
            Color.clear
                .frame(width: vm.geometry.hasPhysicalNotch ? vm.geometry.notchSize.width : 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if showWings {
                    if usageModeActive {
                        // Mode usage : mini-jauges live dans l'aile droite (REQ-USG-35).
                        HStack(spacing: 4) {
                            ForEach(usage.claudeSummaryGauges, id: \.kind) { gauge in
                                BatteryGauge(gauge: gauge, width: 22, height: 11)
                            }
                        }
                        .padding(.trailing, 12)
                    } else if settings.pillShowsSessionCount && sessions.liveCount > 0 {
                        Text("\(sessions.liveCount)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(settings.metricsOpacity))
                            .padding(.trailing, 14)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: pillHeight)
    }

    // MARK: - Panel

    /// Retrait latéral du contenu : les flancs de `NotchShape` sont en retrait du rayon
    /// supérieur par rapport au rect de layout — le contenu doit rester en deçà du clip.
    private var panelSideInset: CGFloat {
        NotchShape.open.topCornerRadius + 14
    }

    private var panelContent: some View {
        let metrics = DensityMetrics.metrics(for: settings.density, titleWeight: settings.titleWeight)
        return VStack(spacing: 0) {
            // Le contenu commence sous la découpe physique.
            Color.clear.frame(height: vm.geometry.pillRestSize.height)
            panelHeader(metrics)
            ScrollView { // scroll sans focus clavier (REQ-NUI-35)
                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    // Section « Act » (2) : prompt actionnable en tête (08 · §2, REQ-NUI-33).
                    if prompts.hasActionablePrompt, settings.promptHandling != .terminalOnly {
                        PromptSectionView(
                            store: prompts,
                            onDecision: { id, decision, source in
                                prompts.decide(id, decision, via: source)
                            },
                            onOpenTerminal: { coordinator.onOpenTerminal?($0) },
                            onTextFieldFocusChange: { coordinator.setTextFieldFocused($0) }
                        )
                        .padding(.horizontal, -2)
                    }
                    ForEach(sections()) { section in
                        if !(section.isEmpty && section.hidesWhenEmpty) {
                            VStack(alignment: .leading, spacing: 6) {
                                if let title = section.title {
                                    Text(title)
                                        .font(metrics.titleFont)
                                        .foregroundStyle(.white.opacity(0.45))
                                        .textCase(.uppercase)
                                }
                                section.content
                            }
                        }
                    }
                }
                .padding(.horizontal, panelSideInset)
                .padding(.bottom, metrics.cardPadding + 10)
            }
            .frame(maxHeight: maxScrollHeight)
        }
    }

    private func panelHeader(_ metrics: DensityMetrics) -> some View {
        ZStack {
            // Usage inline, ALIGNÉ ET CENTRÉ en haut du notch :
            // [Anthropic] %session tokens · [Cursor] $jour tokens.
            UsageInlineView(usage: usage, settings: settings)
            HStack {
                PanelClockView(clock24h: settings.clock24h)
                    .font(metrics.metricFont)
                    .foregroundStyle(.white.opacity(settings.metricsOpacity))
                Spacer()
                // Bouton refresh usage (REQ-USG-31) — shimmer pendant un refresh manuel.
                Button(action: onRefreshUsage) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .rotationEffect(.degrees(usage.refresh == .refreshing(manual: true) ? 360 : 0))
                        .animation(usage.refresh == .refreshing(manual: true)
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                            value: usage.refresh)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, panelSideInset)
        .padding(.vertical, 8)
    }

    /// Plafond de scroll du panel entier : la liste de sessions étant plafonnée séparément,
    /// on laisse la place à usage/serveurs/routes en dessous.
    private var maxScrollHeight: CGFloat {
        settings.sessionListSizing == .fixed ? 560 : 720
    }

    // MARK: - Hover (05 · §3.2)

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.8)) {
                vm.isHoveringPill = true // affordance REQ-NUI-50
            }
            guard vm.state == .pill else { return }
            let delay = settings.hoverIntentDelayMs
            hoverTask = Task { @MainActor [vm, coordinator] in
                try? await Task.sleep(for: .milliseconds(delay)) // délai d'intention
                guard !Task.isCancelled, vm.state == .pill, vm.isHoveringPill else { return }
                coordinator.open(reason: .hover)
            }
        } else {
            hoverTask = Task { @MainActor [vm, coordinator] in
                try? await Task.sleep(for: .milliseconds(100)) // hystérésis fixe
                guard !Task.isCancelled else { return }
                withAnimation { vm.isHoveringPill = false }
                guard vm.state == .panel || vm.state == .opening,
                      !coordinator.settingsWindowIsKey,        // REQ-NUI-21
                      vm.keyFocusOwner != .textField else { return } // REQ-NUI-22
                coordinator.close(reason: .hoverExit)
            }
        }
    }
}

struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Horloge du header (05 · REQ-NUI-39) — timer 1 s actif seulement quand le panel existe.
struct PanelClockView: View {
    let clock24h: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date, clock24h: clock24h))
        }
    }

    static func format(_ date: Date, clock24h: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = clock24h ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }
}
