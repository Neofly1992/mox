import OSLog

public enum BuildInfo {
  #if DEBUG
    public static let configuration = "Debug"
  #else
    public static let configuration = "Release"
  #endif

  public static func logStartup(component: String) {
    Logger(subsystem: "dev.mox", category: "build").info(
      "component=\(component, privacy: .public) configuration=\(configuration, privacy: .public) build=\(Wire.buildID, privacy: .public)"
    )
  }

  /// Debug adds transport metadata only. Neither configuration records request bodies or credentials.
  public static func logResponse(status: Int) {
    #if DEBUG
      Logger(subsystem: "dev.mox", category: "client").debug("stage=response status=\(status)")
    #endif
  }
}
