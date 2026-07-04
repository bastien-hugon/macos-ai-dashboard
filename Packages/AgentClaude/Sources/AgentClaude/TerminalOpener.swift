import AppKit
import DashCore

/// Ouvre le terminal hôte d'une session au bon `cwd` (08 · REQ-ACT-30, ⌥T).
/// Mappe `TERM_PROGRAM` (transmis par le hook) vers l'app, sinon retombe sur Terminal.app.
public enum TerminalOpener {
    private static let bundleIDs: [String: String] = [
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "ghostty": "com.mitchellh.ghostty",
        "vscode": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    @MainActor
    public static func open(termProgram: String?, cwd: String) {
        let workspace = NSWorkspace.shared
        let directory = cwd.isEmpty ? NSHomeDirectory() : cwd
        let bundleID = termProgram.flatMap { bundleIDs[$0] }

        if let bundleID,
           let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = [directory]
            // Ouvre l'app hôte ; la plupart des terminaux acceptent un dossier en argument.
            workspace.open([URL(fileURLWithPath: directory)], withApplicationAt: appURL,
                           configuration: config) { _, error in
                if error != nil {
                    openInTerminal(directory)
                }
            }
        } else {
            openInTerminal(directory)
        }
    }

    @MainActor
    private static func openInTerminal(_ directory: String) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)],
                                withApplicationAt: terminalURL, configuration: config)
    }
}
