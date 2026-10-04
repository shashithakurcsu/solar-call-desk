/// The capabilities of a route, not proof that a backend is connected or configured.
public struct RouteCapabilities: Equatable, Sendable {
    public let supportsDialHandoff: Bool
    public let supportsProgrammaticCalling: Bool
    public let supportsProgrammaticAudio: Bool
    public let canObserveConnection: Bool
    public let canEndCall: Bool
    public let requiresServiceConfiguration: Bool
}

public enum CallRoute: String, CaseIterable, Identifiable, Sendable {
    case phoneRelay
    case service

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .phoneRelay: return "Mac Phone / iPhone relay"
        case .service: return "Conversation service"
        }
    }

    public var capabilities: RouteCapabilities {
        switch self {
        case .phoneRelay:
            // Opening a tel: URL is a handoff to a user-controlled calling app.
            // It does not expose the call's status or two-way audio to this app.
            return RouteCapabilities(
                supportsDialHandoff: true,
                supportsProgrammaticCalling: false,
                supportsProgrammaticAudio: false,
                canObserveConnection: false,
                canEndCall: false,
                requiresServiceConfiguration: false
            )
        case .service:
            // These capabilities require an implemented and configured backend.
            // Selecting this route alone does not make them available.
            return RouteCapabilities(
                supportsDialHandoff: false,
                supportsProgrammaticCalling: true,
                supportsProgrammaticAudio: true,
                canObserveConnection: true,
                canEndCall: true,
                requiresServiceConfiguration: true
            )
        }
    }

    public var limitation: String {
        switch self {
        case .phoneRelay:
            return "The direct Phone handoff does not expose live audio or call status. Sambha’s configured audio bridge and visual Call/Hang Up controls are separate."
        case .service:
            return "Requires a configured telephone and voice backend before calls or assistant conversation are available."
        }
    }
}
