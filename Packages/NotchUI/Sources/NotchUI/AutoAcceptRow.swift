import DashCore
import SwiftUI

/// Rangée compacte des toggles auto-accept (opt-in PAR AGENT) dans le panel du notch.
/// Permissions uniquement — les plans/questions passent toujours par l'humain
/// (`AutoAcceptGate`). Teinte orange assumée : le mode court-circuite les approbations.
public struct AutoAcceptRow: View {
    @Bindable private var settings: SettingsStore

    public init(settings: SettingsStore) {
        _settings = Bindable(settings)
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.badge.checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(anyEnabled ? .orange : .white.opacity(0.4))
            Text("Auto-accept")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            toggle("Claude", $settings.autoAcceptClaude)
            toggle("Cursor", $settings.autoAcceptCursor)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto-accept permissions")
    }

    private var anyEnabled: Bool { settings.autoAcceptClaude || settings.autoAcceptCursor }

    private func toggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(.orange)
        .accessibilityLabel("Auto-accept \(label) permissions")
    }
}
