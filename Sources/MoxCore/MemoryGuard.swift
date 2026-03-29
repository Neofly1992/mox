import Foundation
import Darwin

public final class MemoryGuard: Sendable {
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
    
    private let reservePercent: Double
    
    public init(reservePercent: Double = 0.1) {
        self.reservePercent = reservePercent
    }
    
    public func getMemoryStatus() -> MemoryStatus {
        var size: size_t = MemoryLayout<UInt64>.size
        var memory: UInt64 = 0
        sysctlbyname("hw.memsize", &memory, &size, nil, 0)
        let totalMemory = memory
        
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        
        var usedMemory: UInt64 = 0
        if result == KERN_SUCCESS {
            let pageSize: UInt64 = 4096
            usedMemory = (UInt64(vmStats.active_count) + UInt64(vmStats.wire_count)) * pageSize
        }
        
        let availableMemory = totalMemory > usedMemory ? totalMemory - usedMemory : 0
        let reserve = UInt64(Double(totalMemory) * reservePercent)
        let usableMemory = availableMemory > reserve ? availableMemory - reserve : 0
        
        return MemoryStatus(
            totalMemory: totalMemory,
            usedMemory: usedMemory,
            availableMemory: usableMemory,
            canAllocate: usableMemory > 0
        )
    }
    
    public func canLoadModel(sizeBytes: UInt64) -> MemoryStatus {
        let status = getMemoryStatus()
        
        let adjustedAvailable = UInt64(Double(status.availableMemory) * (1.0 - reservePercent))
        
        return MemoryStatus(
            totalMemory: status.totalMemory,
            usedMemory: status.usedMemory,
            availableMemory: adjustedAvailable,
            canAllocate: adjustedAvailable >= sizeBytes
        )
    }
    
    public func checkAndNotify(sizeBytes: UInt64) -> Result<MemoryStatus, MemoryError> {
        let status = getMemoryStatus()
        let adjustedAvailable = UInt64(Double(status.availableMemory) * (1.0 - reservePercent))
        
        if adjustedAvailable < sizeBytes {
            let neededGB = Double(sizeBytes) / (1024 * 1024 * 1024)
            let availableGB = Double(adjustedAvailable) / (1024 * 1024 * 1024)
            
            return .failure(.insufficientMemory(
                required: neededGB,
                available: availableGB
            ))
        }
        
        return .success(MemoryStatus(
            totalMemory: status.totalMemory,
            usedMemory: status.usedMemory,
            availableMemory: adjustedAvailable,
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
