import Foundation

/// A single completion winner, allowing framework work to drain after a bounded setup wait.
final class PhoneVisualWarmupCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    func complete(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard result == nil else { return nil }
            result = value; let pending = continuation; continuation = nil; return pending
        }
        pending?.resume(returning: value)
    }
    func value() async -> Bool {
        await withCheckedContinuation { pending in
            let ready = lock.withLock { () -> Bool? in
                if let result { return result }
                continuation = pending; return nil
            }
            if let ready { pending.resume(returning: ready) }
        }
    }
}
