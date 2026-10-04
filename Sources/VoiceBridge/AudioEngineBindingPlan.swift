import Foundation

enum AudioEngineEndpoint: CaseIterable, Hashable, Sendable {
    case inputEngineInput, inputEngineOutput, outputEngineInput, outputEngineOutput
    var description: String {
        switch self {
        case .inputEngineInput: "input engine input device ID"
        case .inputEngineOutput: "input engine unused output device ID"
        case .outputEngineInput: "output engine unused input device ID"
        case .outputEngineOutput: "output engine output device ID"
        }
    }
}

struct AudioEngineBindingTarget: Equatable, Sendable {
    let endpoint: AudioEngineEndpoint
    let deviceID: UInt32
}

enum AudioEngineBindingPlan {
    static func make(mode: VoiceBridgeMode, inputID: UInt32, outputID: UInt32) -> [AudioEngineBindingTarget] {
        if mode == .externalBridge {
            // Bidirectional virtual buses must pin even the unused I/O halves. Lazy creation
            // of an unbound half can reset the shared HAL unit to default physical devices.
            return [.init(endpoint: .inputEngineInput, deviceID: inputID), .init(endpoint: .inputEngineOutput, deviceID: inputID),
                    .init(endpoint: .outputEngineInput, deviceID: outputID), .init(endpoint: .outputEngineOutput, deviceID: outputID)]
        }
        // Rehearsal devices can be directional (microphone/speakers). Do not bind an unused
        // output to an input-only microphone, or unused input to output-only speakers.
        return [.init(endpoint: .inputEngineInput, deviceID: inputID), .init(endpoint: .outputEngineOutput, deviceID: outputID)]
    }
    @MainActor static func configure<Node>(_ plan: [AudioEngineBindingTarget], resolve: (AudioEngineEndpoint) -> Node,
                                          bind: (Node, UInt32) throws -> Void) throws {
        // Resolve every required node BEFORE changing any CurrentDevice property. Resolution
        // itself can initialize a shared audio unit and reset a previously applied binding.
        let nodes = plan.map { ($0, resolve($0.endpoint)) }
        for (target, node) in nodes { try bind(node, target.deviceID) }
    }
    static func validate(_ plan: [AudioEngineBindingTarget], observed: [AudioEngineEndpoint: UInt32], context: String) throws {
        for target in plan {
            guard let actual = observed[target.endpoint] else {
                throw VoiceBridgeError.route("\(context): \(target.endpoint.description) unavailable; expected \(target.deviceID). All audio stopped.")
            }
            try AudioRouteIntegrity.equal(target.deviceID, actual, property: target.endpoint.description, context: context)
        }
    }
}
