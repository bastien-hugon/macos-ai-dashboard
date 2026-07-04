import Foundation

/// Auto-mesure des budgets (01 · A9) : échantillon `task_info` toutes les 30 s.
/// Version initiale M0 : log fichier + OSLog ; le signal Doctor arrive au jalon M6.
public actor PerfMonitor {
    public struct Sample: Sendable {
        public let physFootprintBytes: UInt64
        public let timestamp: Date
    }

    private var task: Task<Void, Never>?
    private let intervalSeconds: Double

    public init(intervalSeconds: Double = 30) {
        self.intervalSeconds = intervalSeconds
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [intervalSeconds] in
            while !Task.isCancelled {
                if let sample = Self.sample() {
                    let mb = Double(sample.physFootprintBytes) / 1_048_576
                    DashLog.doctor.info("phys_footprint: \(mb, format: .fixed(precision: 1)) MB")
                    if mb > 150 {
                        DashLog.file(String(format: "budget RAM dépassé : %.1f MB > 150 MB", mb), category: "doctor")
                    }
                }
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public static func sample() -> Sample? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Sample(physFootprintBytes: info.phys_footprint, timestamp: Date())
    }
}
