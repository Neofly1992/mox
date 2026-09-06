import Darwin
import Foundation

/// macOS VM accounting, sampled again before each GPU admission. Inactive pages
/// are reclaimable; compressed/wired/active pages are deliberately not counted.
public enum SystemMemory {
  public static func availableBytes() -> Int? {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var pageSize: vm_size_t = 0
    guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return nil }
    return Int((UInt64(info.free_count) + UInt64(info.inactive_count)) * UInt64(pageSize))
  }
}
