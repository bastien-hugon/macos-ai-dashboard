import DashCore
import SwiftUI

extension GaugeColor {
    var swiftUIColor: Color {
        switch self {
        case .green: Color(red: 0.30, green: 0.82, blue: 0.45)
        case .yellow: Color(red: 0.98, green: 0.80, blue: 0.25)
        case .red: Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }
}

/// Jauge « style batterie » (09 · REQ-USG-15) : rectangle arrondi + ergot, remplissage
/// proportionnel coloré par seuils, shimmer pendant un refresh manuel.
public struct BatteryGauge: View {
    let gauge: GaugeModel
    var width: CGFloat = 34
    var height: CGFloat = 14

    public init(gauge: GaugeModel, width: CGFloat = 34, height: CGFloat = 14) {
        self.gauge = gauge
        self.width = width
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                if let fill = gauge.fillFraction {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(gauge.color.swiftUIColor)
                        .padding(1.5)
                        .frame(width: max(2, (width - 3) * fill), alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: width, height: height)
            .overlay { if gauge.isShimmering { ShimmerOverlay() } }
            // Ergot de batterie
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.35))
                .frame(width: 2, height: height * 0.4)
        }
        .opacity(gauge.fillFraction == nil ? 0.4 : 1)
    }
}

/// Balayage lumineux pendant le refresh (REQ-USG-32).
struct ShimmerOverlay: View {
    @State private var phase: CGFloat = -1
    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, .white.opacity(0.4), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: geo.size.width * 0.6)
                .offset(x: phase * geo.size.width)
                .onAppear {
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        phase = 1.4
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .allowsHitTesting(false)
    }
}

/// Section « Usage » du panel (09 · §4) : une ligne par fenêtre (jauge + légende + %).
public struct UsageSectionView: View {
    let store: UsageStore
    let settings: SettingsStore
    @State private var showDaily = false

    public init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(UsageWindowKind.summaryClaude, id: \.self) { kind in
                if store.windows[kind] != nil, let gauge = store.gauge(for: kind) {
                    gaugeRow(gauge, title: title(kind))
                }
            }
            // Cursor mensuel (M7), affiché s'il est disponible.
            if store.hasCursorMonthly, let gauge = store.gauge(for: .monthly) {
                gaugeRow(gauge, title: "Cursor")
            }
            // Stats journalières (09 · REQ-USG-28).
            if !store.daily.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showDaily.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showDaily ? "chevron.down" : "chevron.right").font(.system(size: 8))
                        Text("Daily usage").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                if showDaily { DailyUsageView(daily: store.daily) }
            }
        }
    }

    private func gaugeRow(_ gauge: GaugeModel, title: String) -> some View {
        HStack(spacing: 10) {
            BatteryGauge(gauge: gauge)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    Text(gauge.percentText).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(gauge.color.swiftUIColor)
                    if gauge.isStale {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 9)).foregroundStyle(.orange.opacity(0.8))
                    }
                }
                if !gauge.caption.isEmpty {
                    Text(gauge.caption).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer()
        }
        .opacity(settings.metricsOpacity)
        // Accessibilité (REQ-NUI-57) : jauge = élément unique.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityLabels.gauge(title: title, percentText: gauge.percentText, caption: gauge.caption))
    }

    private func title(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour: "5-hour"
        case .sevenDay: "7-day"
        case .sevenDayOpus: "7-day Opus"
        case .sevenDaySonnet: "7-day Sonnet"
        case .monthly: "Monthly"
        }
    }
}

/// Mini-histogramme des 14 derniers jours (09 · REQ-USG-28).
struct DailyUsageView: View {
    let daily: [DailyUsage]

    private var maxTokens: Int {
        max(1, daily.map { $0.tokens.inputTokens + $0.tokens.outputTokens }.max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(daily.prefix(14)) { day in
                HStack(spacing: 6) {
                    Text(dayLabel(day.date)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4)).frame(width: 42, alignment: .leading)
                    GeometryReader { geo in
                        let total = day.tokens.inputTokens + day.tokens.outputTokens
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: 0.35, green: 0.65, blue: 0.95).opacity(0.7))
                            .frame(width: geo.size.width * CGFloat(total) / CGFloat(maxTokens))
                    }
                    .frame(height: 8)
                    Text(DashFormat.tokens(day.tokens.inputTokens + day.tokens.outputTokens))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: 44, alignment: .trailing)
                    if let cost = day.costUSD {
                        Text(String(format: "~$%.2f", cost)).font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35)).frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
