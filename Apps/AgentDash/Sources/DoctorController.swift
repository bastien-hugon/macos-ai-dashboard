import AgentClaude
import AppKit
import DashCore
import Darwin
import Foundation
import UserNotifications

/// Exécute les diagnostics (13 · onglet Doctor) : hooks, binaire, socket, usage, notifications.
/// Chaque check produit un statut + un remède en un clic quand c'est réparable.
@MainActor
final class DoctorController {
    private let store: DoctorStore
    private let settings: SettingsStore
    private let paths: DashPaths

    init(store: DoctorStore, settings: SettingsStore, paths: DashPaths) {
        self.store = store
        self.settings = settings
        self.paths = paths
    }

    func run() {
        store.setChecks([
            DoctorCheck(id: "agent", title: "Claude Code detected", status: .checking, detail: "…"),
            DoctorCheck(id: "hooks", title: "Agent hooks", status: .checking, detail: "…", remedyTitle: "Install hooks"),
            DoctorCheck(id: "binary", title: "Hook helper binary", status: .checking, detail: "…", remedyTitle: "Repair"),
            DoctorCheck(id: "socket", title: "IPC socket", status: .checking, detail: "…"),
            DoctorCheck(id: "usage", title: "Usage access (Keychain)", status: .checking, detail: "…"),
            DoctorCheck(id: "notifications", title: "Notifications", status: .checking, detail: "…", remedyTitle: "Open System Settings"),
        ])
        Task { await runChecks() }
    }

    private func runChecks() async {
        // Agent détecté
        let claudeExists = FileManager.default.fileExists(atPath: paths.claudeDir.path)
        store.update("agent", status: claudeExists ? .ok : .warning,
                     detail: claudeExists ? "~/.claude found" : "~/.claude not found — Claude Code not installed")

        // Hooks installés + statut Ready
        let installer = ClaudeHooksInstaller(paths: paths)
        let status = await installer.status()
        switch status {
        case .ready: store.update("hooks", status: .ok, detail: "Ready — hooks installed in settings.json")
        case .notInstalled: store.update("hooks", status: .failure, detail: "Hooks not installed")
        case .damaged(let reason): store.update("hooks", status: .warning, detail: "Damaged: \(reason)")
        case .agentNotDetected: store.update("hooks", status: .warning, detail: "Claude Code not detected")
        }

        // Binaire hook présent
        let binaryExists = FileManager.default.isExecutableFile(atPath: paths.hookBinary.path)
        store.update("binary", status: binaryExists ? .ok : .failure,
                     detail: binaryExists ? "Installed at ~/.agentdash/bin" : "Missing — relaunch to repair")

        // Socket joignable
        let socketOK = testSocketReachable()
        store.update("socket", status: socketOK ? .ok : .warning,
                     detail: socketOK ? "Listening" : "Not reachable")

        // Usage / Keychain
        do {
            _ = try await ClaudeUsagePoller(paths: paths).discoverAccounts()
            store.update("usage", status: .ok, detail: "Keychain access granted")
        } catch {
            store.update("usage", status: .warning, detail: "Keychain access needed — grant to see usage gauges")
        }

        // Notifications autorisées
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            store.update("notifications", status: .ok, detail: "Authorized")
        case .denied:
            store.update("notifications", status: .warning, detail: "Denied — enable in System Settings")
        default:
            store.update("notifications", status: .warning, detail: "Not requested yet")
        }
    }

    /// Le socket IPC accepte-t-il une connexion (self-test round-trip léger) ?
    private func testSocketReachable() -> Bool {
        let path = paths.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    // MARK: - Remèdes

    func applyRemedy(_ checkID: String) {
        switch checkID {
        case "hooks", "binary":
            Task {
                try? await ClaudeHooksInstaller(paths: paths).installOrRepair()
                run()
            }
        case "notifications":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}
