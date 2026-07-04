import AppKit
import DashCore
import SwiftUI

/// Contenu du bouton de la barre de menus (06 · REQ-MBR-02/04) : glyphe + texte d'usage
/// optionnel + point d'attention orange quand un agent attend.
public struct MenuBarLabel: View {
    let sessions: SessionStore
    let usage: UsageStore
    let showsUsage: Bool

    public init(sessions: SessionStore, usage: UsageStore, showsUsage: Bool) {
        self.sessions = sessions
        self.usage = usage
        self.showsUsage = showsUsage
    }

    private var hasWaiting: Bool {
        sessions.displaySessions.contains { $0.state == .waiting }
    }

    public var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                if hasWaiting {
                    Circle().fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2) // REQ-MBR-04
                }
            }
            if showsUsage, let gauge = usage.gauge(for: .fiveHour), gauge.fillFraction != nil {
                Text(gauge.percentText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }
}

/// Contenu du popover de la barre de menus (06 · REQ-MBR-14) : sections plates
/// Usage / Local servers, refresh, et raccourci Settings.
public struct MenuBarPopover: View {
    let sessions: SessionStore
    let usage: UsageStore
    let servers: ServerStore
    let settings: SettingsStore
    let onRefreshUsage: () -> Void
    let onStopServer: (DevServer) -> Void
    let onOpenSettings: () -> Void

    public init(sessions: SessionStore, usage: UsageStore, servers: ServerStore,
                settings: SettingsStore, onRefreshUsage: @escaping () -> Void,
                onStopServer: @escaping (DevServer) -> Void, onOpenSettings: @escaping () -> Void) {
        self.sessions = sessions
        self.usage = usage
        self.servers = servers
        self.settings = settings
        self.onRefreshUsage = onRefreshUsage
        self.onStopServer = onStopServer
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if usage.hasAnyClaudeWindow {
                sectionHeader("Usage", trailing: refreshButton)
                UsageSectionView(store: usage, settings: settings)
            }
            sectionHeader("Local servers", trailing: Text("\(servers.count)").font(.system(size: 10)).foregroundStyle(.secondary))
            ServersSectionView(store: servers, settings: settings, onStop: onStopServer)
            Divider()
            Button {
                onOpenSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ title: String, trailing: some View) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }

    private var refreshButton: some View {
        Button(action: onRefreshUsage) {
            Image(systemName: "arrow.clockwise").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
