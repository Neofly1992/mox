import Foundation
import MoxDomain

/// Validate the safetensors envelope before entering the C++ loader. Reads only
/// bounded metadata, not the weight payload. This is not a provenance checksum.
enum WeightInspection {
  static func names(in file: URL) throws -> Set<String> {
    func invalid() -> MoxError {
      MoxError(.invalidModel, "Invalid or truncated safetensors asset: \(file.lastPathComponent).")
    }
    let asset = try ModelAssetFile(file)
    let size = asset.size
    guard size >= 8 else { throw invalid() }
    let prefix = try asset.read(count: 8)
    let length = prefix.enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << ($1.offset * 8)
    }
    guard length > 0, length <= 16 * 1024 * 1024, length <= max(0, size - 8)
    else { throw invalid() }
    let header = try asset.read(count: Int(length))
    guard let object = try JSONSerialization.jsonObject(with: header) as? [String: Any] else { throw invalid() }
    let payloadSize = size - 8 - Int(length)
    var ranges: [(Int, Int)] = []
    var names = Set<String>()
    let widths = [
      "BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1, "I16": 2, "U16": 2, "F16": 2,
      "BF16": 2, "I32": 4, "U32": 4, "F32": 4, "F64": 8, "I64": 8, "U64": 8,
    ]
    for (name, value) in object where name != "__metadata__" {
      try Task.checkCancellation()
      guard let tensor = value as? [String: Any], let offsets = tensor["data_offsets"] as? [Int],
        offsets.count == 2,
        offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= payloadSize,
        let shape = tensor["shape"] as? [Int], shape.allSatisfy({ $0 >= 0 }),
        let dtype = tensor["dtype"] as? String, let width = widths[dtype]
      else { throw invalid() }
      let bytes = shape.reduce(Double(width)) { $0 * Double($1) }
      guard bytes.isFinite, bytes == Double(offsets[1] - offsets[0]) else { throw invalid() }
      names.insert(name)
      ranges.append((offsets[0], offsets[1]))
    }
    var end = 0
    for range in ranges.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
      guard range.0 == end else { throw invalid() }
      end = range.1
    }
    guard !names.isEmpty, end == payloadSize else { throw invalid() }
    return names
  }
}
