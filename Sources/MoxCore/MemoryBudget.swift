import Foundation

/// Cache budget for `ModelRegistry`.
///
/// The registry wants to know "how much cache memory (KV cache,
/// intermediate activations, scratch) is left for me to play with?"
/// in absolute bytes. `cacheBudget(totalRAMBytes:weightsPeakBytes:)`
/// answers that:
///
///   budget = clamp(totalRAMBytes * surplusFraction, floor=1GB, cap=48GB)
///           - weightsPeakBytes
///
/// `surplusFraction` defaults to 0.5, matching MTPLX's
/// `_AUTO_BUDGET_SURPLUS_FRACTION`. We use that exact constant so a
/// user moving from MTPLX to mox sees the same behaviour on the same
/// hardware.
///
/// `weightsPeakBytes` is subtracted from the surplus so the budget
/// reflects what's left *after* resident model weights. A negative
/// result (the user has loaded more than the raw cap) collapses to
/// zero — the registry then refuses any further loads.
///
/// Pure function: no `MemoryGuard` reads, no actor isolation, no I/O.
/// That makes the budget trivially testable in isolation and lets the
/// registry compute it offline (e.g. on config load).
public enum MemoryBudget {

    /// `_AUTO_BUDGET_SURPLUS_FRACTION` from MTPLX. 50% of total RAM
    /// is the cache ceiling; the rest is reserved for the OS + other
    /// processes + headroom for the model's own allocator.
    public static let defaultSurplusFraction: Double = 0.5

    /// Lower bound on the surplus before subtracting weights. A
    /// 16 GB Mac gets the same floor as a 96 GB Mac: 1 GB cache is
    /// the minimum useful working set.
    public static let minimumCacheBytes: Int64 = 1 << 30 // 1 GiB

    /// Upper bound on the surplus before subtracting weights. Beyond
    /// this, the OS file cache + Metal driver + MLX allocator start
    /// to thrash; MTPLX caps at the same 48 GiB.
    public static let maximumCacheBytes: Int64 = 48 << 30 // 48 GiB

    /// Compute the cache budget in bytes.
    /// - Parameters:
    ///   - totalRAMBytes: physical memory, in bytes. Must be `>= 0`.
    ///   - weightsPeakBytes: peak memory of currently-resident model
    ///     weights (across all loaded models). Must be `>= 0`.
    ///   - surplusFraction: how much of `totalRAMBytes` is available
    ///     for cache before weights. Defaults to 0.5.
    /// - Returns: non-negative cache budget in bytes.
    public static func cacheBudget(
        totalRAMBytes: Int64,
        weightsPeakBytes: Int64,
        surplusFraction: Double = defaultSurplusFraction
    ) -> Int64 {
        precondition(totalRAMBytes >= 0, "totalRAMBytes must be non-negative")
        precondition(weightsPeakBytes >= 0, "weightsPeakBytes must be non-negative")
        precondition(surplusFraction > 0 && surplusFraction <= 1, "surplusFraction must be in (0, 1]")
        let raw = Int64(Double(totalRAMBytes) * surplusFraction)
        let clamped = min(max(raw, minimumCacheBytes), maximumCacheBytes)
        let net = clamped - weightsPeakBytes
        return max(net, 0)
    }
}