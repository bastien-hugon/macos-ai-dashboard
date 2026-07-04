import Foundation
import Observation

/// Résultat d'un check Doctor (13 · onglet Doctor).
public struct DoctorCheck: Identifiable, Sendable {
    public enum Status: Sendable, Equatable { case ok, warning, failure, checking }

    public let id: String
    public let title: String
    public var status: Status
    public var detail: String
    /// Libellé du remède en un clic (nil = aucun).
    public var remedyTitle: String?

    public init(id: String, title: String, status: Status, detail: String, remedyTitle: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remedyTitle = remedyTitle
    }
}

/// Store des diagnostics — alimenté par le DoctorController (app).
@MainActor @Observable
public final class DoctorStore {
    public private(set) var checks: [DoctorCheck] = []
    public private(set) var lastRun: Date?

    public init() {}

    public func setChecks(_ checks: [DoctorCheck]) {
        self.checks = checks
        lastRun = Date()
    }

    public func update(_ id: String, status: DoctorCheck.Status, detail: String) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].status = status
        checks[index].detail = detail
    }

    public var overall: DoctorCheck.Status {
        if checks.contains(where: { $0.status == .failure }) { return .failure }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        if checks.contains(where: { $0.status == .checking }) { return .checking }
        return .ok
    }
}
