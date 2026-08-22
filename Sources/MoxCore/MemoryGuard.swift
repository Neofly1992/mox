import Foundation
import Darwin
import MoxShared

/// Read-only memory availability probe.
///
/// Apple Silicon unified memory uses the compressor as its primary
/// pressure signal; on Intel it is `wired + active`. We read both via
/// `host_statistics64` and add them together so the check is correct
/// regardless of architecture.
public struct MemoryGuard: Sendable {

    public static let shared = MemoryGuard()

    public struct MemoryStatus: Sendable {
        public let totalMemory: UInt64
        public let usedMemory: UInt64
        public let availableMemory: UInt64
        public let canAllocate: Bool

        public var totalGB: Double { Double(totalMemory) / (1024 * 1024 * 1024) }
        public var availableGB: Double { Double(availableMemory) / (1024 * 1024 * 1024) }
        public var usedGB: Double { Double(usedMemory) / (1024 * 1024 * 1024) }
    }

    /// Fraction of total memory Mox keeps in reserve for the OS and other
    /// processes. Applied exactly once in `getMemoryStatus`; callers that
    /// multiply by `(1 - reservePercent)` again are double-counting and
    /// silently under-budget the model.
    public let reservePercent: Double

    public init(reservePercent: Double = 0.1) {
        self.reservePercent = reservePercent
    }

    public func getMemoryStatus() -> MemoryStatus {
        // Total physical memory (hw.memsize).
        var memSize = MemoryLayout<UInt64>.size
        var memory: UInt64 = 0
        let hwErr = sysctlbyname("hw.memsize", &memory, &memSize, nil, 0)
        let totalMemory: UInt64 = hwErr == 0 ? memory : 0
        if hwErr != 0 {
            moxLog.error("sysctl hw.memsize failed: errno=\(errno, privacy: .public)")
        }

        // Active + wired + compressed pages.
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &vmStats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        // vm_kernel_page_size is 4096 on Intel, 16384 on Apple Silicon.
        // Hardcoding 4096 understates used memory on the latter and lets
        // callers over-commit.
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageBytes = UInt64(max(pageSize, 1))

        var active: UInt64 = 0
        var wire: UInt64 = 0
        var compressed: UInt64 = 0
        if kerr == KERN_SUCCESS {
            active = UInt64(vmStats.active_count)
            wire = UInt64(vmStats.wire_count)
            compressed = UInt64(vmStats.compressor_page_count)
        } else {
            moxLog.error("host_statistics64 failed: kern=\(kerr, privacy: .public)")
        }
        let usedMemory = (active + wire + compressed) * pageBytes

        let rawAvailable = totalMemory > usedMemory ? totalMemory - usedMemory : 0
        let reserve = UInt64(Double(totalMemory) * reservePercent)
        let availableMemory = rawAvailable > reserve ? rawAvailable - reserve : 0

        return MemoryStatus(
            totalMemory: totalMemory,
            usedMemory: usedMemory,
            availableMemory: availableMemory,
            canAllocate: availableMemory > 0
        )
    }

    /// `availableMemory` is already reserve-adjusted; do not multiply by
    /// `(1 - reservePercent)` again or the effective reserve becomes
    /// 1 - (1 - r)^2 (e.g. 0.1 becomes about 19%).
    public func canLoadModel(sizeBytes: UInt64) -> MemoryStatus {
        let status = getMemoryStatus()
        return MemoryStatus(
            totalMemory: status.totalMemory,
            usedMemory: status.usedMemory,
            availableMemory: status.availableMemory,
            canAllocate: status.availableMemory >= sizeBytes
        )
    }

    public func checkAndNotify(sizeBytes: UInt64) -> Result<MemoryStatus, MemoryError> {
        let status = getMemoryStatus()
        if status.availableMemory < sizeBytes {
            let neededGB = Double(sizeBytes) / (1024 * 1024 * 1024)
            let availableGB = Double(status.availableMemory) / (1024 * 1024 * 1024)
            return .failure(.insufficientMemory(required: neededGB, available: availableGB))
        }
        return .success(MemoryStatus(
            totalMemory: status.totalMemory,
            usedMemory: status.usedMemory,
            availableMemory: status.availableMemory,
            canAllocate: true
        ))
    }
}

public enum MemoryError: Error, LocalizedError {
    case insufficientMemory(required: Double, available: Double)

    public var errorDescription: String? {
        switch self {
        case .insufficientMemory(let required, let available):
            return String(format: "Insufficient memory to load model. Required: %.1f GB, Available: %.1f GB", required, available)
        }
    }
}