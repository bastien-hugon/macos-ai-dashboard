import AppKit
import Carbon.HIToolbox
import DashCore

/// Raccourcis éphémères pour les prompts (08 · REQ-ACT-24..29). Carbon
/// `RegisterEventHotKey` : consomme l'événement, **aucune permission TCC**. Enregistrés
/// uniquement pendant qu'un prompt actionnable est affiché ; désenregistrés dès qu'un champ
/// texte prend le focus (pour ne pas transformer une frappe en décision). Keycodes résolus
/// par caractère via la disposition courante (⌘A doit taper « A », pas « Q » sur AZERTY).
@MainActor
public final class HotkeyManager {
    public enum Action: Sendable { case allow, deny, alwaysAllow, openTerminal }

    public var onAction: ((Action) -> Void)?
    public private(set) var registrationFailures: [String] = []

    private var hotkeyRefs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private var actionsByID: [UInt32: Action] = [:]
    private var installed = false

    private static let signature: OSType = 0x41474448 // 'AGDH'

    public init() {}

    /// Enregistre le jeu de hotkeys adapté au type de prompt focalisé.
    public func register(for capabilities: PromptCapabilities, isPlan: Bool, isQuestion: Bool) {
        unregister()
        installHandlerIfNeeded()
        registrationFailures = []

        // Questions : ⌘A/⌘N inactifs (REQ-ACT-24) ; ⌥T toujours.
        if !isQuestion {
            add(.allow, char: "a", modifiers: UInt32(cmdKey), label: "⌘A")
            add(.deny, char: "n", modifiers: UInt32(cmdKey), label: "⌘N")
        }
        if capabilities.canAlwaysAllow {
            add(.alwaysAllow, char: "a", modifiers: UInt32(optionKey), label: "⌥A")
        }
        add(.openTerminal, char: "t", modifiers: UInt32(optionKey), label: "⌥T")
    }

    /// Suspend les hotkeys (champ texte first responder, REQ-ACT-29).
    public func suspend() { unregister() }

    public func unregister() {
        for ref in hotkeyRefs where ref != nil { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        actionsByID.removeAll()
    }

    // MARK: -

    private func add(_ action: Action, char: String, modifiers: UInt32, label: String) {
        guard let keyCode = Self.keyCode(for: char) else {
            registrationFailures.append("\(label) unavailable on this keyboard")
            return
        }
        let id = UInt32(actionsByID.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr {
            hotkeyRefs.append(ref)
            actionsByID[id] = action
        } else {
            registrationFailures.append("\(label) could not be registered (another app may use it)")
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            MainActor.assumeIsolated {
                if let action = manager.actionsByID[hotKeyID.id] {
                    manager.onAction?(action)
                }
            }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Keycode virtuel produisant `char` avec la disposition clavier courante.
    static func keyCode(for char: String) -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return ansiFallback(char)
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        let target = Character(char.lowercased())

        return data.withUnsafeBytes { raw -> UInt32? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return ansiFallback(char)
            }
            for code in UInt16(0)..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars
                )
                if status == noErr, length > 0,
                   let scalar = Unicode.Scalar(chars[0]), Character(scalar) == target {
                    return UInt32(code)
                }
            }
            return ansiFallback(char)
        }
    }

    private static func ansiFallback(_ char: String) -> UInt32? {
        switch char.lowercased() {
        case "a": UInt32(kVK_ANSI_A)
        case "n": UInt32(kVK_ANSI_N)
        case "t": UInt32(kVK_ANSI_T)
        default: nil
        }
    }
}
