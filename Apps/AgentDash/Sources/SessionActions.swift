import AppKit
import DashCore
import Darwin

/// Actions sur une session (07 · REQ-SES-37..41) : Kill sécurisé, Copy as Markdown, Dismiss,
/// Open Terminal. Le Kill re-valide le PID (uid + vivacité) avant tout signal.
@MainActor
enum SessionActions {
    static func copyMarkdown(_ session: Session) {
        let markdown = SessionMarkdown.render(session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    static func kill(_ session: Session, store: SessionStore) {
        guard let pid = session.pid else { return }
        // Garde-fous : jamais un PID système, jamais soi-même, uid == user.
        guard pid >= 100, pid != getpid() else { return }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
              info.kp_eproc.e_ucred.cr_uid == getuid() else { return }

        Task.detached {
            _ = Darwin.kill(pid, SIGTERM)
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                if Darwin.kill(pid, 0) != 0 { break }
            }
            if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
            await MainActor.run { store.markEnded(session.id, reason: .killed) }
        }
    }

    static func openTerminal(_ session: Session) {
        let program: String? = if case .terminal(let p) = session.host { p } else { nil }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath ?? NSHomeDirectory(), isDirectory: true))
        _ = program
    }
}
