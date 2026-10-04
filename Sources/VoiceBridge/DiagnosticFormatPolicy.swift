import AVFoundation
import AudioToolbox

/// Hardware-side I/O formats describe the selected device. Client-side formats may still
/// describe the default device until the tap and graph connections explicitly configure them.
enum DiagnosticFormatPolicy {
    struct Plan {
        let source: AVAudioFormat
        let sink: AVAudioFormat
    }
    static func plan(device: AudioDevice, hardwareSource: AVAudioFormat, hardwareSink: AVAudioFormat,
                     clientSource: AVAudioFormat, clientSink: AVAudioFormat) throws -> Plan {
        guard usable(hardwareSource, channels: device.inputChannels), usable(hardwareSink, channels: device.outputChannels) else {
            throw failure(device: device, stage: "hardware format validation", hardwareSource: hardwareSource,
                          hardwareSink: hardwareSink, clientSource: clientSource, clientSink: clientSink)
        }
        return try Plan(source: AudioClientFormat.make(hardware: hardwareSource), sink: AudioClientFormat.make(hardware: hardwareSink))
    }
    static func validateConfigured(device: AudioDevice, plan: Plan, hardwareSource: AVAudioFormat,
                                   hardwareSink: AVAudioFormat, clientSource: AVAudioFormat, clientSink: AVAudioFormat) throws {
        guard clientSource == plan.source, clientSink == plan.sink else {
            throw failure(device: device, stage: "client format configuration", hardwareSource: hardwareSource,
                          hardwareSink: hardwareSink, clientSource: clientSource, clientSink: clientSink)
        }
    }
    static func failure(device: AudioDevice, stage: String, hardwareSource: AVAudioFormat, hardwareSink: AVAudioFormat,
                        clientSource: AVAudioFormat, clientSink: AVAudioFormat) -> VoiceBridgeError {
        .route("\(device.name) [\(device.uid)]: diagnostic \(stage) failed. Expected \(device.inputChannels) input/\(device.outputChannels) output channels; "
            + "hardware source \(describe(hardwareSource)), sink \(describe(hardwareSink)); "
            + "client source \(describe(clientSource)), sink \(describe(clientSink)).")
    }
    private static func usable(_ format: AVAudioFormat, channels: Int) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && channels >= 2 && format.channelCount == channels
            && format.sampleRate.isFinite && (8_000...192_000).contains(format.sampleRate)
    }
    static func describe(_ format: AVAudioFormat) -> String {
        let kind: String
        switch format.commonFormat {
        case .pcmFormatFloat32: kind = "Float32"
        case .pcmFormatFloat64: kind = "Float64"
        case .pcmFormatInt16: kind = "Int16"
        case .pcmFormatInt32: kind = "Int32"
        default: kind = "format \(format.streamDescription.pointee.mFormatID)"
        }
        return "\(format.channelCount)ch/\(format.sampleRate)Hz/\(kind)/\(format.isInterleaved ? "interleaved" : "deinterleaved")/layout \(format.channelLayout.map { String($0.layoutTag) } ?? "none")"
    }
}
