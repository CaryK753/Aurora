import Foundation

/// Executes one blocking read at a time. Only the caller's completion runs on the main actor.
@MainActor
final class BackgroundSnapshot<Input: Sendable, Value: Sendable> {
    private let queue: DispatchQueue
    private let read: @Sendable (Input) -> Value
    private var inFlight = false
    private var pending: (Input, @MainActor (Value) -> Void)?

    init(label: String, read: @escaping @Sendable (Input) -> Value) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.read = read
    }

    @discardableResult
    func request(_ input: Input, _ completion: @escaping @MainActor (Value) -> Void) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        queue.async { [weak self, read] in
            let value = read(input)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                let pending = self.pending
                self.pending = nil
                if let (input, next) = pending {
                    self.request(input, next)
                } else {
                    completion(value)
                }
            }
        }
        return true
    }
    /// Invalidate a stale in-flight result and keep at most the newest replacement.
    func requestLatest(_ input: Input, _ completion: @escaping @MainActor (Value) -> Void) {
        if !request(input, completion) { pending = (input, completion) }
    }
}

func readInBackground<Value: Sendable>(on queue: DispatchQueue = .global(qos: .utility), _ read: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        queue.async { continuation.resume(returning: read()) }
    }
}

extension BackgroundSnapshot where Input == Void {
    convenience init(label: String, read: @escaping @Sendable () -> Value) {
        self.init(label: label, read: { _ in read() })
    }

    @discardableResult
    func request(_ completion: @escaping @MainActor (Value) -> Void) -> Bool {
        request((), completion)
    }
}
