import Hummingbird
import MoxDomain

/// Both listeners share resource and business failure status semantics.
enum HTTPFailureStatus {
  static func status(_ error: MoxError) -> HTTPResponse.Status {
    switch error.code {
    case .authenticationFailed: .unauthorized
    case .notFound: .notFound
    case .busy, .serviceConflict: .conflict
    case .bodyTooLarge: .contentTooLarge
    case .queueFull, .queueTimeout: .tooManyRequests
    case .resourceLimit, .shuttingDown: .serviceUnavailable
    case .loadFailed, .generationFailed, .storageFailed: .internalServerError
    default: .badRequest
    }
  }
}
