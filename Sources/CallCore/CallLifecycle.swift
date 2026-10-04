import Foundation

public enum CallEndReason: String, Equatable, Sendable {
    case completed
    case cancelled
    case remoteEnded
    case rejectedBeforeDial
    /// Explicit user confirmation after checking the external calling app.
    case userConfirmedEnded
    /// A target-bound hangup click followed by the call panel closing; not carrier evidence.
    case hangupUIPanelClosed
}

public enum CallUncertainty: String, Equatable, Sendable {
    case requestOutcomeUnknown
    case endOutcomeUnknown
    case externalCallStatusUnavailable
}

public enum CallState: Equatable, Sendable {
    case idle
    case requesting(UUID)
    case requestSubmitted(UUID)
    case ringing(UUID)
    case connected(UUID)
    case ending(UUID)
    case ended(UUID, CallEndReason)
    case unverified(UUID, CallUncertainty)

    public var attemptID: UUID? {
        switch self {
        case .idle: return nil
        case let .requesting(id), let .requestSubmitted(id), let .ringing(id),
             let .connected(id), let .ending(id), let .ended(id, _), let .unverified(id, _):
            return id
        }
    }

    public var title: String {
        switch self {
        case .idle: return "Ready"
        case .requesting: return "Submitting request"
        case .requestSubmitted: return "Request submitted"
        case .ringing: return "Ringing"
        case .connected: return "Connected"
        case .ending: return "End requested"
        case .ended(_, .hangupUIPanelClosed): return "Hangup sent · popup closed"
        case .ended: return "Ended"
        case .unverified: return "Call status unverified"
        }
    }
}

/// Status notifications require backend evidence, except the explicitly named
/// user-report and hangup-UI receipt events. URL open is only requestSubmitted.
public enum CallEvent: Equatable, Sendable {
    case begin(UUID)
    case requestSubmitted(UUID)
    case ringing(UUID)
    case connected(UUID)
    case requestEnd(UUID)
    case ended(UUID, CallEndReason)
    case rejectedBeforeDial(UUID)
    case requestOutcomeUnknown(UUID)
    case endOutcomeUnknown(UUID)
    case externalCallStatusUnavailable(UUID)
    case userConfirmedEnded(UUID)
    case hangupUIPanelClosed(UUID)

    public var attemptID: UUID {
        switch self {
        case let .begin(id), let .requestSubmitted(id), let .ringing(id),
             let .connected(id), let .requestEnd(id), let .ended(id, _),
             let .rejectedBeforeDial(id), let .requestOutcomeUnknown(id),
             let .endOutcomeUnknown(id), let .externalCallStatusUnavailable(id),
             let .userConfirmedEnded(id), let .hangupUIPanelClosed(id):
            return id
        }
    }
}

/// A local lifecycle reducer with no dialing, audio, networking, or retry effects.
/// An ambiguous request stays locked until backend end, explicit user report,
/// or a separately named target-bound hangup UI receipt reconciles the local job.
public struct CallLifecycle: Equatable, Sendable {
    public private(set) var state: CallState = .idle

    public init() {}

    public var canStartNewCall: Bool {
        switch state {
        case .idle, .ended: return true
        default: return false
        }
    }

    public var activeAttemptID: UUID? {
        canStartNewCall ? nil : state.attemptID
    }

    public var needsReconciliation: Bool {
        if case .unverified = state { return true }
        return false
    }

    /// Returns false for stale, duplicate, or unsafe transitions.
    @discardableResult
    public mutating func reduce(_ event: CallEvent) -> Bool {
        if case let .begin(id) = event {
            guard canStartNewCall, state.attemptID != id else { return false }
            state = .requesting(id)
            return true
        }

        guard !canStartNewCall, activeAttemptID == event.attemptID else { return false }
        let id = event.attemptID

        switch event {
        case .begin:
            return false
        case .requestSubmitted:
            guard case .requesting = state else { return false }
            state = .requestSubmitted(id)
        case .ringing:
            switch state {
            case .requesting, .requestSubmitted,
                 .unverified(_, .requestOutcomeUnknown),
                 .unverified(_, .externalCallStatusUnavailable):
                state = .ringing(id)
            default: return false
            }
        case .connected:
            switch state {
            case .requesting, .requestSubmitted, .ringing,
                 .unverified(_, .requestOutcomeUnknown),
                 .unverified(_, .externalCallStatusUnavailable):
                state = .connected(id)
            default: return false
            }
        case .requestEnd:
            // Do not send another end request while its outcome is unknown.
            switch state {
            case .requestSubmitted, .ringing, .connected,
                 .unverified(_, .requestOutcomeUnknown),
                 .unverified(_, .externalCallStatusUnavailable):
                state = .ending(id)
            default: return false
            }
        case let .ended(_, reason):
            // Rejection has a stricter transition below; user confirmation has a
            // separate event so callers cannot confuse it with backend evidence.
            guard reason != .rejectedBeforeDial, reason != .userConfirmedEnded, reason != .hangupUIPanelClosed else { return false }
            state = .ended(id, reason)
        case .rejectedBeforeDial:
            switch state {
            case .requesting, .requestSubmitted, .unverified(_, .requestOutcomeUnknown):
                state = .ended(id, .rejectedBeforeDial)
            default: return false
            }
        case .requestOutcomeUnknown:
            switch state {
            case .requesting, .requestSubmitted:
                state = .unverified(id, .requestOutcomeUnknown)
            default: return false
            }
        case .endOutcomeUnknown:
            guard case .ending = state else { return false }
            state = .unverified(id, .endOutcomeUnknown)
        case .externalCallStatusUnavailable:
            guard case .requestSubmitted = state else { return false }
            state = .unverified(id, .externalCallStatusUnavailable)
        case .userConfirmedEnded:
            // The UI must ask the user to check the calling app before this event.
            switch state {
            case .requestSubmitted, .unverified, .ending:
                state = .ended(id, .userConfirmedEnded)
            default: return false
            }
        case .hangupUIPanelClosed:
            guard case .ending = state else { return false }
            state = .ended(id, .hangupUIPanelClosed)
        }
        return true
    }
}
