import AppKit
import DashCore
import SwiftUI

/// Section « Local servers » (10 · §4) : rows port/projet/uptime + actions Open/Copy/Stop
/// (arrêt en deux temps « Confirm? », REQ-SRV-31).
public struct ServersSectionView: View {
    let store: ServerStore
    let settings: SettingsStore
    let onStop: (DevServer) -> Void

    public init(store: ServerStore, settings: SettingsStore, onStop: @escaping (DevServer) -> Void) {
        self.store = store
        self.settings = settings
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.servers.isEmpty {
                VStack(spacing: 4) {
                    Text("No local servers")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    Text("Dev servers on ports 3000–9999 will show up here.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            } else {
                ForEach(store.servers) { server in
                    ServerRowView(server: server, settings: settings, onStop: { onStop(server) })
                }
            }
        }
    }
}

struct ServerRowView: View {
    let server: DevServer
    let settings: SettingsStore
    let onStop: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(":\(String(server.id.port))")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(server.displayName)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    if let runner = server.packageRunner {
                        Text(runner.rawValue).font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                Text("\(server.projectName) · up \(DashFormat.elapsed(server.uptime))")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .opacity(server.stopState == .gone ? 0.4 : 1)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            iconButton("arrow.up.forward.square", help: "Open") {
                NSWorkspace.shared.open(server.url) // sans activer AgentDash (REQ-SRV-29)
            }
            iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.url.absoluteString, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1)); copied = false }
            }
            stopButton
        }
    }

    @ViewBuilder private var stopButton: some View {
        switch server.stopState {
        case .none, .gone:
            Button("Stop") { onStop() }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red.opacity(0.85))
        case .confirming:
            Button("Confirm?") { onStop() }
                .buttonStyle(.plain).font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.8)))
        case .terminating:
            Text("Stopping…").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Section « Quick Routes » (11 · §2) : chips ouvrant les dossiers agents dans le Finder.
public struct QuickRoutesSectionView: View {
    let routes: [QuickRoute]
    let onOpen: (QuickRoute, String) -> Void

    public init(routes: [QuickRoute], onOpen: @escaping (QuickRoute, String) -> Void) {
        self.routes = routes
        self.onOpen = onOpen
    }

    public var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(routes.filter { !$0.existing.isEmpty }) { route in
                if route.existing.count == 1 {
                    chip(route.title) { onOpen(route, route.existing[0]) }
                        .help(route.existing[0])
                } else {
                    Menu {
                        ForEach(route.existing, id: \.self) { path in
                            Button((path as NSString).lastPathComponent == route.title.lowercased()
                                   ? path : (path as NSString).abbreviatingWithTildeInPath) {
                                onOpen(route, path)
                            }
                        }
                    } label: {
                        chipLabel("\(route.title) ›")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title) }.buttonStyle(.plain)
    }

    private func chipLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

/// Section « Fast Actions » (11 · §2.B) : commandes shell sauvegardées, exécution en un clic
/// (jamais au premier clic accidentel : bouton play explicite par action).
public struct FastActionsSectionView: View {
    let store: FastActionStore
    let onRun: (FastAction) -> Void

    public init(store: FastActionStore, onRun: @escaping (FastAction) -> Void) {
        self.store = store
        self.onRun = onRun
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.actions) { action in
                HStack(spacing: 8) {
                    Button {
                        onRun(action)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.45).opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(action.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        Text(action.command).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                    }
                    Spacer()
                    if let code = action.lastExitCode {
                        Image(systemName: code == 0 ? "checkmark.circle" : "xmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(code == 0 ? .green.opacity(0.7) : .red.opacity(0.7))
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
            }
        }
    }
}
