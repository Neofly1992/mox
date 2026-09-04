import Foundation
import Darwin
import MoxShared

/// Reads the host's hardware fingerprint for `DefaultModelSuggester`:
/// - Apple Silicon generation (M1 / M2 / M3 / M4 / M5 / unknown)
/// - Total physical RAM (bytes)
/// - Whether we're on an Apple Silicon SoC at all (vs. Intel)
///
/// Pure read-only — never blocks, never allocates beyond the
/// `brandString` buffer. `Sendable` because every property is
/// value-type and the constructor is the only mutation point.
public struct HardwareClassifier: Sendable {

    /// `true` when `uname -m` returns `arm64`. On Intel Macs the
    /// brand string still names a chip but MLX isn't supported there,
    /// so callers can short-circuit recommendations.
    public let isAppleSilicon: Bool

    /// Total physical RAM, in bytes. Zero if the probe failed —
    /// callers should fall back to conservative defaults in that
    /// case (32 GB → suggest 9B).
    public let totalMemoryBytes: UInt64

    /// Apple Silicon generation parsed from `machdep.cpu.brand_string`.
    /// `unknown` when the brand string doesn't match a known pattern
    /// (older A-series, Intel chips, virtualised CPU).
    public let chipGeneration: ChipGeneration

    /// The raw brand string (`Apple M2 Pro`, `Apple M4`, …). Useful
    /// for diagnostic output; not consumed by `DefaultModelSuggester`.
    public let brandString: String

    public enum ChipGeneration: String, Sendable, Codable, Equatable {
        case m1, m3, m4, m5
        case unknown
    }

    public init() {
        // uname -m
        var isARM = false
        var sysinfo = utsname()
        if uname(&sysinfo) == 0 {
            let machineMirror = withUnsafePointer(to: &sysinfo.machine) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { cstr in
                    String(cString: cstr)
                }
            }
            isARM = machineMirror == "arm64"
        }

        // hw.memsize
        var memSize = MemoryLayout<UInt64>.size
        var memory: UInt64 = 0
        let hwErr = sysctlbyname("hw.memsize", &memory, &memSize, nil, 0)
        let totalRAM: UInt64 = hwErr == 0 ? memory : 0

        // machdep.cpu.brand_string
        var brand = ""
        var brandSize = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &brandSize, nil, 0) == 0, brandSize > 0 {
            var brandBuf = [CChar](repeating: 0, count: brandSize)
            if sysctlbyname("machdep.cpu.brand_string", &brandBuf, &brandSize, nil, 0) == 0 {
                brand = String(cString: brandBuf)
            }
        }

        self.isAppleSilicon = isARM
        self.totalMemoryBytes = totalRAM
        self.brandString = brand
        self.chipGeneration = HardwareClassifier.parseChip(brand)
    }

    /// Constructor for tests / configuration overrides (e.g. running
    /// mox-server inside CI with a mocked hardware probe).
    public init(isAppleSilicon: Bool, totalMemoryBytes: UInt64, brandString: String, chipGeneration: ChipGeneration) {
        self.isAppleSilicon = isAppleSilicon
        self.totalMemoryBytes = totalMemoryBytes
        self.brandString = brandString
        self.chipGeneration = chipGeneration
    }

    /// Parse `Apple M2 Pro` / `Apple M4` / `Apple M1` / etc. into the
    /// `ChipGeneration` enum. Falls back to `.unknown` for empty
    /// strings, Intel chips, or future generations mox doesn't yet
    /// know about.
    private static func parseChip(_ brand: String) -> ChipGeneration {
        let lower = brand.lowercased()
        // Order matters — check M5 before M4 before M3 etc. since the
        // prefix match would otherwise resolve a future "M5" to "M"
        // and stop there.
        if lower.contains("apple m5") { return .m5 }
        if lower.contains("apple m4") { return .m4 }
        if lower.contains("apple m3") { return .m3 }
        if lower.contains("apple m1") { return .m1 }
        return .unknown
    }
}