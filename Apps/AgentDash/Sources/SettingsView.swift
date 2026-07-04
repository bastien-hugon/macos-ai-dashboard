import DashCore
import NotchUI
import ServiceManagement
import SwiftUI

/// Fenêtre Settings (13) : sidebar 7 onglets + contenu à effet immédiat sur SettingsStore.
struct SettingsView: View {
    let settings: SettingsStore
    let doctor: DoctorStore
    let usage: UsageStore
    let fastActions: FastActionStore
    let onRunDoctor: () -> Void
    let onDoctorRemedy: (String) -> Void
    let onSendTestNotification: () -> Void
    let onRetryKeychain: () -> Void
    let onQuit: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", notifications = "Notifications", appearance = "Appearance"
        case usage = "Usage", shortcuts = "Shortcuts", doctor = "Doctor", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .notifications: "bell"
            case .appearance: "paintbrush"
            case .usage: "gauge.with.dots.needle.67percent"
            case .shortcuts: "keyboard"
            case .doctor: "stethoscope"
            case .about: "info.circle"
            }
        }
    }

    @State private var selection: Tab = {
        // QA : ouvre directement un onglet via env (dev).
        if let raw = ProcessInfo.processInfo.environment["AGENTDASH_SETTINGS_TAB"],
           let tab = Tab(rawValue: raw.prefix(1).uppercased() + raw.dropFirst()) {
            return tab
        }
        return .general
    }()

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(180)
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive, action: onQuit) {
                    Label("Quit AgentDash", systemImage: "power").frame(maxWidth: .infinity)
                }
                .padding(8)
            }
        } detail: {
            ScrollView {
                content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(selection.rawValue)
        }
        .frame(minWidth: 640, minHeight: 460)
        .onChange(of: selection) { _, tab in if tab == .doctor { onRunDoctor() } }
        .onAppear { if selection == .doctor { onRunDoctor() } }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .general: generalTab
        case .notifications: notificationsTab
        case .appearance: appearanceTab
        case .usage: usageTab
        case .shortcuts: shortcutsTab
        case .doctor: doctorTab
        case .about: aboutTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        settingsGroup {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLoginEnabled() },
                set: { setLaunchAtLogin($0) }
            ))
            Divider()
            Toggle("Show in notch", isOn: bind(\.notchEnabled))
            Toggle("Show in menu bar", isOn: bind(\.menuBarEnabled))
            Toggle("Auto-expand on attention", isOn: bind(\.autoExpandOnAttention))
            Divider()
            picker("Prompt handling", bindEnum(\.promptHandling), PromptHandling.allCases) { mode in
                switch mode {
                case .notch: "Notch"
                case .both: "Notch + terminal"
                case .terminalOnly: "Terminal only"
                }
            }
            Divider()
            Toggle("Claude Code hooks", isOn: bind(\.claudeHooksEnabled))
                .help("Installs hooks in ~/.claude/settings.json")
            Divider()
            fastActionsEditor
        }
    }

    // MARK: - Fast Actions CRUD (11 · REQ-QRF-14)

    @State private var newActionTitle = ""
    @State private var newActionCommand = ""

    private var fastActionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fast Actions").font(.headline)
            Text("Shell commands you can run from the notch.").font(.caption).foregroundStyle(.secondary)
            ForEach(fastActions.actions) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(action.title).font(.system(size: 12, weight: .medium))
                        Text(action.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { fastActions.remove(action.id) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless)
                }
                .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            HStack {
                TextField("Title", text: $newActionTitle).frame(width: 120)
                TextField("Command (e.g. npm run dev)", text: $newActionCommand)
                Button("Add") {
                    guard !newActionTitle.isEmpty, !newActionCommand.isEmpty else { return }
                    fastActions.upsert(FastAction(title: newActionTitle, command: newActionCommand))
                    newActionTitle = ""; newActionCommand = ""
                }
                .disabled(newActionTitle.isEmpty || newActionCommand.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Launch at login (14 · REQ-LIC-06)

    private func launchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            DashLog.ui.error("launch at login: \(error.localizedDescription)")
        }
    }

    // MARK: - Notifications

    private var notificationsTab: some View {
        settingsGroup {
            Toggle("Enable notifications", isOn: bind(\.notificationsMasterEnabled))
            Toggle("Play sound", isOn: bind(\.notificationSoundEnabled))
                .disabled(!settings.notificationsMasterEnabled)
            Divider()
            Group {
                Toggle("Permission requests", isOn: bind(\.notifyPermission))
                Toggle("Budget alerts", isOn: bind(\.notifyBudget))
                Toggle("Stuck sessions", isOn: bind(\.notifyStuck))
                Toggle("Task complete", isOn: bind(\.notifyTaskComplete))
            }
            .disabled(!settings.notificationsMasterEnabled)
            Divider()
            HStack {
                Text("Budget threshold (5-hour)")
                Spacer()
                Stepper("\(settings.budgetThreshold5h)%", value: bind(\.budgetThreshold5h), in: 50...100, step: 5)
                    .fixedSize()
            }
            HStack {
                Text("Budget threshold (7-day)")
                Spacer()
                Stepper("\(settings.budgetThreshold7d)%", value: bind(\.budgetThreshold7d), in: 50...100, step: 5)
                    .fixedSize()
            }
            Divider()
            Button("Send Test Notification", action: onSendTestNotification)
        }
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        settingsGroup {
            picker("Pill width", bindEnum(\.pillWidthMode), PillWidthMode.allCases) { $0.rawValue.capitalized }
            picker("Panel width", bindEnum(\.panelWidth), PanelWidth.allCases) { $0.rawValue.capitalized }
            picker("Density", bindEnum(\.density), Density.allCases) { $0.rawValue.capitalized }
            picker("Title weight", bindEnum(\.titleWeight), TitleWeight.allCases) { $0.rawValue.capitalized }
            picker("Session list", bindEnum(\.sessionListSizing), ListSizing.allCases) { $0.rawValue.capitalized }
            Divider()
            Toggle("24-hour clock", isOn: bind(\.clock24h))
            Toggle("Show session count in pill", isOn: bind(\.pillShowsSessionCount))
            Toggle("Usage mode in pill", isOn: bind(\.pillUsageMode))
            Toggle("Hide pill when idle", isOn: bind(\.pillHideWhenIdle))
            Divider()
            HStack {
                Text("Glass opacity")
                Slider(value: bind(\.glassOpacity), in: 0...1)
                Text(settings.glassOpacity >= 1 ? "Opaque" : "\(Int(settings.glassOpacity * 100))%")
                    .monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            Toggle("Frosted rim", isOn: bind(\.frostedRim))
            Toggle("Depth-lit interface", isOn: bind(\.depthLitEnabled))
            HStack {
                Text("Metrics opacity")
                Slider(value: bind(\.metricsOpacity), in: 0.3...1)
            }
            Toggle("Hide from screen recording", isOn: bind(\.hideFromScreenRecording))
        }
    }

    // MARK: - Usage

    private var usageTab: some View {
        settingsGroup {
            Toggle("Track Claude usage", isOn: bind(\.claudeUsageEnabled))
            Toggle("Track Cursor usage", isOn: bind(\.cursorUsageEnabled))
            Picker("Cursor measure", selection: bind(\.cursorMeasure)) {
                Text("Spend").tag("spend")
                Text("Weighted").tag("weighted")
                Text("Auto").tag("auto")
                Text("API").tag("api")
            }
            .pickerStyle(.menu).fixedSize()
            .disabled(!settings.cursorUsageEnabled)
            Divider()
            Toggle("Count down from 100%", isOn: bind(\.countdownFrom100))
            Toggle("Show usage in menu bar", isOn: bind(\.menuBarShowsUsage))
            Divider()
            if !usage.accounts.isEmpty {
                ForEach(usage.accounts) { account in
                    LabeledContent("Account", value: account.label)
                }
            } else {
                Button("Retry Keychain access", action: onRetryKeychain)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        settingsGroup {
            Text("Prompt shortcuts are active only while a prompt is shown and the notch is focused.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            shortcutRow("Allow", "⌘A")
            shortcutRow("Deny", "⌘N")
            shortcutRow("Always Allow (Claude only)", "⌥A")
            shortcutRow("Open Terminal", "⌥T")
        }
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
        }
    }

    // MARK: - Doctor

    private var doctorTab: some View {
        settingsGroup {
            HStack {
                Text("Diagnostics").font(.headline)
                Spacer()
                Button("Re-run", action: onRunDoctor)
            }
            Divider()
            ForEach(doctor.checks) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(check.status)).foregroundStyle(color(check.status))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.system(size: 13, weight: .medium))
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let remedy = check.remedyTitle, check.status != .ok {
                        Button(remedy) { onDoctorRemedy(check.id) }.controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func icon(_ status: DoctorCheck.Status) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        case .checking: "circle.dotted"
        }
    }

    private func color(_ status: DoctorCheck.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .failure: .red
        case .checking: .secondary
        }
    }

    // MARK: - About

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (build \(build))"
    }

    private var aboutTab: some View {
        settingsGroup {
            Text("AgentDash").font(.title2).bold()
            Text(appVersion).foregroundStyle(.secondary)
            Divider()
            Text("To update: replace AgentDash.app with a newer build.")
                .font(.callout)
            Text("Your settings, hooks and backups are preserved across updates.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Open logs") {
                NSWorkspace.shared.open(DashPaths.live().logsDir)
            }
            Text("Your coding agents, in the Mac notch.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func settingsGroup(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: 480, alignment: .leading)
    }

    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    private func bindEnum<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        bind(keyPath)
    }

    private func picker<T: Hashable>(_ title: String, _ binding: Binding<T>, _ options: [T],
                                     _ label: @escaping (T) -> String) -> some View {
        Picker(title, selection: binding) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.menu).fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
