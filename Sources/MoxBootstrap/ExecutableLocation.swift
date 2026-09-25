import Darwin
import Foundation
import MoxDomain

public enum ExecutableLocation {
  /// dyld resolves the running image independently of argv[0] and the shell's PATH.
  public static func current() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var bytes = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&bytes, &size) == 0 else {
      throw MoxError(.incompatibleService, "Cannot locate the running executable.")
    }
    return URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL
      .resolvingSymlinksInPath()
  }
}
