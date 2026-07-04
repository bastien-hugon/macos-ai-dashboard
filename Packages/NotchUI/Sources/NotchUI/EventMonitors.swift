import AppKit

/// Moniteurs de clic extérieur (05 · §3.5) : global + local, limités à `leftMouseDown`,
/// installés uniquement quand au moins un panel est ouvert.
@MainActor
final class EventMonitors {
    static let shared = EventMonitors()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onLeftMouseDown: ((NSPoint) -> Void)?

    private init() {}

    func install() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            DispatchQueue.main.async {
                EventMonitors.shared.onLeftMouseDown?(NSEvent.mouseLocation)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            DispatchQueue.main.async {
                EventMonitors.shared.onLeftMouseDown?(NSEvent.mouseLocation)
            }
            return event
        }
    }

    func uninstall() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
