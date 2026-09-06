/// Determines who may control the lifetime of a local service instance.
public enum ServiceOwnership: String, Codable, Sendable {
    case foreground
    case appOwned
    case externallyManaged
}
