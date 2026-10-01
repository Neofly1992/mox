import Foundation

/// One observer per shared IO task. Cancelling a waiter releases only that waiter;
/// the library retains ownership of the underlying verification.
final class SharedVerificationWait<Value: Sendable>: Sendable {
  private struct State {
    var result: Result<Value, any Error>?
    var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
  }
  private let lock = NSLock()
  private nonisolated(unsafe) var state = State()
  init(_ task: Task<Value, any Error>) {
    Task {
      let result = await task.result
      let pending = lock.withLock {
        state.result = result
        let pending = Array(state.waiters.values)
        state.waiters.removeAll()
        return pending
      }
      for waiter in pending { waiter.resume(with: result) }
    }
  }
  func value() async throws -> Value {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else if let result = state.result {
            continuation.resume(with: result)
          } else {
            state.waiters[id] = continuation
          }
        }
      }
    } onCancel: {
      let waiter = self.lock.withLock { self.state.waiters.removeValue(forKey: id) }
      waiter?.resume(throwing: CancellationError())
    }
  }
}
