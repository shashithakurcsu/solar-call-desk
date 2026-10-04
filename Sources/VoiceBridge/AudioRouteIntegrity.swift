import AVFoundation
import Foundation

enum AudioRouteIntegrity {
    static func query<T>(property: String, context: String, _ read: () throws -> T) throws -> T {
        do { return try read() }
        catch { throw VoiceBridgeError.route("\(context): querying \(property) failed: \(error.localizedDescription)") }
    }
    static func equal<T: Equatable>(_ expected: T, _ actual: T, property: String, context: String) throws {
        guard expected == actual else {
            throw VoiceBridgeError.route("\(context): \(property) changed; expected \(expected), observed \(actual). All audio stopped.")
        }
    }
    struct Engines {
        let inputHardware: AVAudioFormat
        let inputClient: AVAudioFormat
        let outputHardware: AVAudioFormat
        let outputClient: AVAudioFormat
        let inputRunning: Bool
        let outputRunning: Bool

        func validate(expected: Engines, requireRunning: Bool, context: String) throws {
            for (property, before, after) in [
                ("input hardware format", expected.inputHardware, inputHardware),
                ("input client format", expected.inputClient, inputClient),
                ("output hardware format", expected.outputHardware, outputHardware),
                ("output client format", expected.outputClient, outputClient)
            ] {
                guard before == after else {
                    throw VoiceBridgeError.route("\(context): \(property) changed; expected \(DiagnosticFormatPolicy.describe(before)), observed \(DiagnosticFormatPolicy.describe(after)). All audio stopped.")
                }
            }
            if requireRunning {
                try AudioRouteIntegrity.equal(true, inputRunning, property: "input engine running", context: context)
                try AudioRouteIntegrity.equal(true, outputRunning, property: "output engine running", context: context)
            }
        }
    }
}

/// Stable values only: stream topology omits AudioBufferList padding and transient data pointers.
enum AudioRoutePropertyValue: Equatable, CustomStringConvertible {
    case missing, unsigned(UInt32), rate(Double), channels([UInt32])
    var description: String {
        switch self {
        case .missing: return "unavailable"
        case .unsigned(let value): return String(value)
        case .rate(let value): return "\(value) Hz"
        case .channels(let value): return "buffer channel counts \(value)"
        }
    }
}

/// Late callbacks cannot revalidate an ended session, including after the same object starts again.
struct AudioRouteNotificationLifetime {
    private var generation = UUID()
    private(set) var isMonitoring = false
    mutating func begin() -> UUID { generation = UUID(); isMonitoring = false; return generation }
    mutating func activate(_ token: UUID) { if token == generation { isMonitoring = true } }
    mutating func stop() { generation = UUID(); isMonitoring = false }
    func accepts(_ token: UUID) -> Bool { isMonitoring && generation == token }
}
