import DashCore
import ServiceManagement
import SwiftUI

/// Fenêtre Welcome guidée (14 · REQ-LIC-01..10) : 4 étapes, ≤ 3 interactions jusqu'à la
/// première session. Utilise le même moteur d'installation de hooks que Settings.
struct OnboardingView: View {
    let settings: SettingsStore
    let claudeStatus: () async -> HookInstallStatus
    let cursorStatus: () async -> HookInstallStatus
    let installClaude: () async -> Void
    let installCursor: () async -> Void
    let requestNotifications: () -> Void
    let onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, agents, notifications, launch }
    @State private var step: Step = .welcome
    @State private var claude: HookInstallStatus = .notInstalled
    @State private var cursor: HookInstallStatus = .notInstalled
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            footer
        }
        .frame(width: 520, height: 460)
        .background(Color(.windowBackgroundColor))
        .task(id: step) { await refreshStatuses() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .agents: agentsStep
        case .notifications: notificationsStep
        case .launch: launchStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Welcome to AgentDash").font(.largeTitle).bold()
            Text("Your coding agents, in the Mac notch.")
                .font(.title3).foregroundStyle(.secondary)
            Text("See every Claude Code and Cursor session, answer permissions, and track token usage — without leaving your editor.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
        }
    }

    private var agentsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your agents").font(.title).bold()
            Text("AgentDash installs shared hooks so it can see what your agents are doing. Nothing leaves your Mac.")
                .foregroundStyle(.secondary)
            agentCard("Claude Code", status: claude, install: { Task { await installClaude(); await refreshStatuses() } })
            agentCard("Cursor", status: cursor, install: { Task { await installCursor(); await refreshStatuses() } })
        }
    }

    private func agentCard(_ name: String, status: HookInstallStatus, install: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(statusLabel(status)).font(.caption).foregroundStyle(statusColor(status))
            }
            Spacer()
            switch status {
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .agentNotDetected:
                Text("Not detected").foregroundStyle(.secondary)
            default:
                Button("Install hooks", action: install)
            }
        }
        .padding().background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var notificationsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.badge").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Stay in the loop").font(.title).bold()
            Text("Get notified when an agent needs approval, hits a usage threshold, or finishes a task. You can reply to permissions right from the notification.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
            Button("Enable Notifications") { requestNotifications() }
                .controlSize(.large)
        }
    }

    private var launchStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "power").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Launch at login").font(.title).bold()
            Text("Keep AgentDash running so your agents are always in view.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Toggle("Launch AgentDash at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                .padding(.horizontal, 40)
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
            }
            Spacer()
            Text("\(step.rawValue + 1) / \(Step.allCases.count)").foregroundStyle(.secondary).font(.caption)
            Spacer()
            Button(step == .launch ? "Done" : "Continue") {
                if step == .launch { onFinish() }
                else { withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .launch } }
            }
            .keyboardShortcut(.defaultAction) // Entrée (REQ-LIC-02)
            .controlSize(.large)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: -

    private func refreshStatuses() async {
        claude = await claudeStatus()
        cursor = await cursorStatus()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        // SMAppService (macOS 13+, REQ-LIC-06).
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            DashLog.ui.error("launch at login: \(error.localizedDescription)")
        }
    }

    private func statusLabel(_ s: HookInstallStatus) -> String {
        switch s {
        case .ready: "Hooks installed"
        case .notInstalled: "Hooks not installed yet"
        case .damaged(let r): "Needs repair: \(r)"
        case .agentNotDetected: "Not installed on this Mac"
        }
    }

    private func statusColor(_ s: HookInstallStatus) -> Color {
        switch s {
        case .ready: .green
        case .agentNotDetected: .secondary
        default: .orange
        }
    }
}
