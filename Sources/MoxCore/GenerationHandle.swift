import Foundation
import MoxDomain
import OSLog

/// A single-consumer bounded channel with a reserved terminal slot. Producer callbacks
/// never suspend or allocate an unbounded intermediary. Overflow cancels work and is
/// reported after GPU completion, even when the consumer hasn't started reading yet.
public final class GenerationHandle: Sendable {
  private struct State {
    var events: [GenerationEvent] = []
    var bytes = 0
    var sequence = 0
    var waiter: CheckedContinuation<GenerationEvent?, Never>?
    var terminal = false
    var cancelled = false
    var cancelAt: ContinuousClock.Instant?
    var stoppedAt: ContinuousClock.Instant?
    var overflow = false
    var task: Task<Void, Never>?
  }
  private let lock = NSLock()
  private nonisolated(unsafe) var state = State()
  public let requestID: UUID
  private let capacity: Int
  private let byteLimit: Int
  public init(
    requestID: UUID, capacity: Int = StreamLimits.pendingEvents,
    byteLimit: Int = StreamLimits.pendingTextBytes
  ) {
    self.requestID = requestID
    self.capacity = max(1, capacity)
    self.byteLimit = max(1, byteLimit)
  }
  func own(_ task: Task<Void, Never>) {
    lock.withLock {
      state.task = task
      if state.cancelled { task.cancel() }
    }
  }
  public var isCancelled: Bool { lock.withLock { state.cancelled } }
  public func cancel() {
    lock.withLock {
      if !state.terminal && !state.cancelled {
        state.cancelAt = .now
        state.cancelled = true
        state.task?.cancel()
      }
    }
  }
  var cancellationDuration: Duration? {
    lock.withLock { state.cancelAt.map { $0.duration(to: state.stoppedAt ?? .now) } }
  }
  public func waitUntilStopped() async {
    let task = lock.withLock { state.task }
    await task?.value
  }
  @discardableResult public func emit(_ payload: GenerationPayload) -> Bool {
    lock.withLock {
      guard !state.terminal, !state.cancelled, !payload.isTerminal else { return false }
      let size = Self.size(payload)
      if size > byteLimit
        || (state.waiter == nil
          && (state.events.count >= capacity || state.bytes + size > byteLimit))
      {
        state.cancelAt = .now
        state.overflow = true
        state.cancelled = true
        state.task?.cancel()
        return false
      }
      append(payload, size: size)
      return true
    }
  }
  func finish(_ payload: GenerationPayload) {
    lock.withLock {
      guard !state.terminal else { return }
      let final: GenerationPayload
      if state.overflow {
        final = .failed(MoxError(.slowConsumer, "Output consumer exceeded the bounded buffer."))
      } else if state.cancelled {
        final = .finished(.cancelled)
      } else {
        final = payload
      }
      state.stoppedAt = .now
      state.terminal = true
      append(final, size: 0)
      if case .failed(let error) = final {
        Logger(subsystem: "dev.mox", category: "runtime").error(
          "request=\(self.requestID.uuidString, privacy: .public) error=\(error.code.rawValue, privacy: .public)"
        )
      }
    }
  }
  private func append(_ payload: GenerationPayload, size: Int) {
    let event = GenerationEvent(requestID: requestID, sequence: state.sequence, payload: payload)
    state.sequence += 1
    if let waiter = state.waiter {
      state.waiter = nil
      waiter.resume(returning: event)
    } else {
      state.events.append(event)
      state.bytes += size
    }
  }
  private static func size(_ payload: GenerationPayload) -> Int {
    if case .contentDelta(let text) = payload { return text.utf8.count }
    return 0
  }
  public struct Events: AsyncSequence, Sendable {
    public typealias Element = GenerationEvent
    let handle: GenerationHandle
    public struct AsyncIterator: AsyncIteratorProtocol {
      let handle: GenerationHandle
      public mutating func next() async -> GenerationEvent? { await handle.next() }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(handle: handle) }
  }
  public var events: Events { Events(handle: self) }
  private func next() async -> GenerationEvent? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.withLock {
          if !state.events.isEmpty {
            let event = state.events.removeFirst()
            state.bytes -= Self.size(event.payload)
            continuation.resume(returning: event)
          } else if state.terminal {
            continuation.resume(returning: nil)
          } else {
            precondition(state.waiter == nil, "Generation events have one consumer")
            state.waiter = continuation
          }
        }
      }
    } onCancel: {
      self.cancel()
    }
  }
}
