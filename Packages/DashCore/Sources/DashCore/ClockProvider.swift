import Foundation

/// Horloge injectable (15 · REQ-TST-02) : tout code dépendant du temps (machine à états,
/// rollover des fenêtres d'usage, `isStale`, GC de sessions) consomme ce protocole,
/// jamais `Date()` ni `ContinuousClock` directement. Les tests pilotent le temps sans `sleep`.
public protocol ClockProvider: Sendable {
    /// Heure murale courante.
    var now: Date { get }
    /// Référence monotone (insensible aux changements d'horloge murale), en secondes.
    /// Continue de courir pendant le sommeil (`mach_continuous_time`).
    var monotonicSeconds: TimeInterval { get }
}

public struct SystemClock: ClockProvider {
    public init() {}
    public var now: Date { Date() }
    public var monotonicSeconds: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }
}
