import Foundation
import Observation

// MARK: - Types de réglages (02 · §6.1 — sous-ensemble M0, complété aux jalons suivants)

public enum PillWidthMode: String, Codable, CaseIterable, Sendable {
    case auto, wide, ultraWide
}

public enum PanelWidth: String, Codable, CaseIterable, Sendable {
    case normal, wide, ultraWide

    /// Largeurs en points (05 · REQ-NUI-32) [HYPOTHÈSE — à calibrer].
    public var points: CGFloat {
        switch self {
        case .normal: 640
        case .wide: 760
        case .ultraWide: 880
        }
    }
}

public enum Density: String, Codable, CaseIterable, Sendable {
    case compact, regular, colossal
}

public enum TitleWeight: String, Codable, CaseIterable, Sendable {
    case regular, medium, semibold, bold
}

public enum ListSizing: String, Codable, CaseIterable, Sendable {
    case fixed, growable
}

public enum PromptHandling: String, Codable, CaseIterable, Sendable {
    case notch, both, terminalOnly
}

public enum PreferredScreen: RawRepresentable, Equatable, Sendable {
    case builtinThenMain
    case active
    case uuid(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "builtinThenMain": self = .builtinThenMain
        case "active": self = .active
        default:
            guard rawValue.hasPrefix("uuid:") else { return nil }
            self = .uuid(String(rawValue.dropFirst(5)))
        }
    }

    public var rawValue: String {
        switch self {
        case .builtinThenMain: "builtinThenMain"
        case .active: "active"
        case .uuid(let u): "uuid:\(u)"
        }
    }
}

// MARK: - Store

/// Réglages persistés (UserDefaults) — source de vérité UI, mutations sur MainActor.
/// Tout changement s'applique immédiatement (05 · REQ-NUI-44) : les vues observent ce store.
@MainActor @Observable
public final class SettingsStore {
    private let defaults: UserDefaults

    // General
    public var notchEnabled: Bool { didSet { save(notchEnabled, "notchEnabled") } }
    public var menuBarEnabled: Bool { didSet { save(menuBarEnabled, "menuBarEnabled") } }
    public var autoExpandOnAttention: Bool { didSet { save(autoExpandOnAttention, "autoExpandOnAttention") } }
    public var promptHandling: PromptHandling { didSet { save(promptHandling.rawValue, "promptHandling") } }
    public var onboardingCompleted: Bool { didSet { save(onboardingCompleted, "onboardingCompleted") } }
    /// Hooks Claude Code installés dans ~/.claude/settings.json (03 · REQ-CLA-01).
    public var claudeHooksEnabled: Bool { didSet { save(claudeHooksEnabled, "claudeHooksEnabled") } }
    /// Auto-accept opt-in PAR AGENT : répond « allow » aux demandes de PERMISSION sans
    /// interaction (les plans et questions restent affichés — décisions de contenu).
    /// Off par défaut ; basculable depuis le notch et Settings.
    public var autoAcceptClaude: Bool { didSet { save(autoAcceptClaude, "autoAcceptClaude") } }
    public var autoAcceptCursor: Bool { didSet { save(autoAcceptCursor, "autoAcceptCursor") } }

    // Usage (M3)
    public var claudeUsageEnabled: Bool { didSet { save(claudeUsageEnabled, "claudeUsageEnabled") } }
    public var countdownFrom100: Bool { didSet { save(countdownFrom100, "countdownFrom100") } }
    public var budgetThreshold5h: Int { didSet { save(budgetThreshold5h, "budgetThreshold5h") } }
    public var budgetThreshold7d: Int { didSet { save(budgetThreshold7d, "budgetThreshold7d") } }

    // Cursor usage (M7)
    public var cursorUsageEnabled: Bool { didSet { save(cursorUsageEnabled, "cursorUsageEnabled") } }
    public var cursorMeasure: String { didSet { save(cursorMeasure, "cursorMeasure") } } // spend/weighted/auto/api

    // Menu bar (M5)
    public var menuBarShowsUsage: Bool { didSet { save(menuBarShowsUsage, "menuBarShowsUsage") } }

    // Notifications (M5)
    public var notificationsMasterEnabled: Bool { didSet { save(notificationsMasterEnabled, "notificationsMasterEnabled") } }
    public var notificationSoundEnabled: Bool { didSet { save(notificationSoundEnabled, "notificationSoundEnabled") } }
    public var notifyPermission: Bool { didSet { save(notifyPermission, "notifyPermission") } }
    public var notifyBudget: Bool { didSet { save(notifyBudget, "notifyBudget") } }
    public var notifyStuck: Bool { didSet { save(notifyStuck, "notifyStuck") } }
    public var notifyTaskComplete: Bool { didSet { save(notifyTaskComplete, "notifyTaskComplete") } }

    // Notch — comportement
    public var hoverIntentDelayMs: Int { didSet { save(hoverIntentDelayMs, "hoverIntentDelayMs") } }
    public var preferredScreen: PreferredScreen { didSet { save(preferredScreen.rawValue, "preferredScreen") } }
    /// Afficher la surface sur TOUS les écrans (REQ-NUI-16), sinon uniquement l'écran préféré.
    public var showOnAllScreens: Bool { didSet { save(showOnAllScreens, "showOnAllScreens") } }
    /// Section « Local servers » dépliée dans le panel (repliée par défaut — gain de place).
    public var serversSectionExpanded: Bool { didSet { save(serversSectionExpanded, "serversSectionExpanded") } }

    // Pill
    public var pillWidthMode: PillWidthMode { didSet { save(pillWidthMode.rawValue, "pillWidthMode") } }
    public var pillShowsSessionCount: Bool { didSet { save(pillShowsSessionCount, "pillShowsSessionCount") } }
    public var pillUsageMode: Bool { didSet { save(pillUsageMode, "pillUsageMode") } }
    public var pillHideWhenIdle: Bool { didSet { save(pillHideWhenIdle, "pillHideWhenIdle") } }
    public var pillExpandedOnly: Bool { didSet { save(pillExpandedOnly, "pillExpandedOnly") } }

    // Panel / Appearance
    public var panelWidth: PanelWidth { didSet { save(panelWidth.rawValue, "panelWidth") } }
    public var sessionListSizing: ListSizing { didSet { save(sessionListSizing.rawValue, "sessionListSizing") } }
    public var density: Density { didSet { save(density.rawValue, "density") } }
    public var titleWeight: TitleWeight { didSet { save(titleWeight.rawValue, "titleWeight") } }
    public var clock24h: Bool { didSet { save(clock24h, "clock24h") } }
    public var glassOpacity: Double { didSet { save(glassOpacity, "glassOpacity") } }
    public var frostedRim: Bool { didSet { save(frostedRim, "frostedRim") } }
    public var depthLitEnabled: Bool { didSet { save(depthLitEnabled, "depthLitEnabled") } }
    public var metricsOpacity: Double { didSet { save(metricsOpacity, "metricsOpacity") } }
    public var hideFromScreenRecording: Bool { didSet { save(hideFromScreenRecording, "hideFromScreenRecording") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: Self.prefixed(key)) as? Bool ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: Self.prefixed(key)) as? Int ?? fallback
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: Self.prefixed(key)) as? Double ?? fallback
        }
        func raw<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            (defaults.string(forKey: Self.prefixed(key)).flatMap(T.init(rawValue:))) ?? fallback
        }

        notchEnabled = bool("notchEnabled", true)
        menuBarEnabled = bool("menuBarEnabled", true)
        autoExpandOnAttention = bool("autoExpandOnAttention", true)
        promptHandling = raw("promptHandling", PromptHandling.both)
        onboardingCompleted = bool("onboardingCompleted", false)
        claudeHooksEnabled = bool("claudeHooksEnabled", true)
        autoAcceptClaude = bool("autoAcceptClaude", false)
        autoAcceptCursor = bool("autoAcceptCursor", false)
        claudeUsageEnabled = bool("claudeUsageEnabled", true)
        countdownFrom100 = bool("countdownFrom100", false)
        budgetThreshold5h = int("budgetThreshold5h", 80)
        budgetThreshold7d = int("budgetThreshold7d", 80)
        cursorUsageEnabled = bool("cursorUsageEnabled", true)
        cursorMeasure = Self.cursorMeasureRawValue(defaults: defaults)
        menuBarShowsUsage = bool("menuBarShowsUsage", true)
        notificationsMasterEnabled = bool("notificationsMasterEnabled", true)
        notificationSoundEnabled = bool("notificationSoundEnabled", true)
        notifyPermission = bool("notifyPermission", true)
        notifyBudget = bool("notifyBudget", true)
        notifyStuck = bool("notifyStuck", true)
        notifyTaskComplete = bool("notifyTaskComplete", true)
        hoverIntentDelayMs = int("hoverIntentDelayMs", 200)
        preferredScreen = raw("preferredScreen", PreferredScreen.builtinThenMain)
        showOnAllScreens = bool("showOnAllScreens", false)
        serversSectionExpanded = bool("serversSectionExpanded", false)
        pillWidthMode = raw("pillWidthMode", PillWidthMode.auto)
        pillShowsSessionCount = bool("pillShowsSessionCount", true)
        pillUsageMode = bool("pillUsageMode", false)
        pillHideWhenIdle = bool("pillHideWhenIdle", false)
        pillExpandedOnly = bool("pillExpandedOnly", false)
        panelWidth = raw("panelWidth", PanelWidth.normal)
        sessionListSizing = raw("sessionListSizing", ListSizing.fixed)
        density = raw("density", Density.regular)
        titleWeight = raw("titleWeight", TitleWeight.semibold)
        clock24h = bool("clock24h", true)
        // Noir profond opaque par défaut : le panel doit se fondre dans la découpe physique
        // (calibrage utilisateur du 3 juillet 2026). Le verre reste une option de Settings.
        glassOpacity = double("glassOpacity", 1.0)
        frostedRim = bool("frostedRim", false)
        depthLitEnabled = bool("depthLitEnabled", true)
        metricsOpacity = double("metricsOpacity", 0.85)
        hideFromScreenRecording = bool("hideFromScreenRecording", false)
    }

    nonisolated private static func prefixed(_ key: String) -> String { "agentdash.\(key)" }

    /// Lecture thread-safe de `cursorMeasure` (UserDefaults) pour les closures Sendable
    /// appelées hors MainActor (poller d'usage Cursor, M7).
    nonisolated public static func cursorMeasureRawValue(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: prefixed("cursorMeasure")) ?? "weighted"
    }

    private func save(_ value: some Any, _ key: String) {
        defaults.set(value, forKey: Self.prefixed(key))
    }
}
