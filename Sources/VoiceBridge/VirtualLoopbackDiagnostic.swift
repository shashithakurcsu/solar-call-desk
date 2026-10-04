@preconcurrency import AVFoundation
import AudioToolbox
import Combine
import Foundation

public struct VirtualLoopbackConfiguration: Sendable {
    public let twoChannelDevice: AudioDevice
    public let sixteenChannelDevice: AudioDevice
    public let noActiveCallsAcknowledged: Bool
    public init(twoChannelDevice: AudioDevice, sixteenChannelDevice: AudioDevice, noActiveCallsAcknowledged: Bool) {
        self.twoChannelDevice = twoChannelDevice; self.sixteenChannelDevice = sixteenChannelDevice
        self.noActiveCallsAcknowledged = noActiveCallsAcknowledged
    }
    public func validate(devices: [AudioDevice]) throws {
        guard noActiveCallsAcknowledged else {
            throw VoiceBridgeError.configuration("Close calls and audio recording apps before explicitly starting the diagnostic.")
        }
        guard twoChannelDevice.id != sixteenChannelDevice.id, twoChannelDevice.uid != sixteenChannelDevice.uid else {
            throw VoiceBridgeError.route("Choose the two independent BlackHole primary devices.")
        }
        for (selected, uid, count) in [(twoChannelDevice, "BlackHole2ch_UID", 2), (sixteenChannelDevice, "BlackHole16ch_UID", 16)] {
            guard selected.uid == uid, let fresh = devices.first(where: { $0.id == selected.id }),
                  fresh.uid == selected.uid, fresh.isVirtual, fresh.inputChannels == count, fresh.outputChannels == count else {
                throw VoiceBridgeError.route("Diagnostic accepts only the available primary BlackHole 2ch and 16ch devices; mirrors and physical devices are excluded.")
            }
        }
    }
}

public enum VirtualLoopbackDiagnosticState: Equatable, Sendable {
    case idle, preparing, testingTwoChannel, testingSixteenChannel, completed, failed
    public var isActive: Bool { self == .preparing || self == .testingTwoChannel || self == .testingSixteenChannel }
}
enum DiagnosticAuthorizationDecision {
    case approved, request, rejected
    static func evaluate(_ status: AVAuthorizationStatus, allowPermissionRequest: Bool) -> Self {
        if status == .authorized { return .approved }
        if status == .notDetermined && allowPermissionRequest { return .request }
        return .rejected
    }
}
public struct VirtualLoopbackMetrics: Equatable, Sendable {
    public let ownRMS: Double
    public let otherRMS: Double
    /// Phase-independent correlation with the known tone on the device's first channel pair.
    public let correlation: Double
    public let gain: Double
    public let leakageRatio: Double
    public let analyzedFrames: Int
    public let capturedFrames: Int
    public let captureSampleRate: Double
    public let passed: Bool
}
public struct VirtualLoopbackReport: Equatable, Sendable {
    public var scopeDescription: String {
        "Tests the averaged first channel pair only. Channels 3–16 and opposite-polarity leakage are not verified. Phone, FaceTime and WhatsApp routing remain unverified."
    }
    public let twoChannelDevice: AudioDevice
    public let sixteenChannelDevice: AudioDevice
    public let twoChannelInputSampleRate: Double
    public let twoChannelOutputSampleRate: Double
    public let sixteenChannelInputSampleRate: Double
    public let sixteenChannelOutputSampleRate: Double
    public let twoChannel: VirtualLoopbackMetrics
    public let sixteenChannel: VirtualLoopbackMetrics
    public var passed: Bool { twoChannel.passed && sixteenChannel.passed }
}

/// No network path. Construction is inert. Start alone requests permission and uses selected virtual audio units.
/// A pass proves these buses in this diagnostic, and makes no claim about Phone, FaceTime, or WhatsApp routing.
@MainActor public final class VirtualLoopbackDiagnostic: ObservableObject {
    @Published public private(set) var state: VirtualLoopbackDiagnosticState = .idle
    @Published public private(set) var result: VirtualLoopbackReport?
    @Published public private(set) var lastError: String?
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var buses: [DiagnosticBus] = []
    public init() {}

    public func start(configuration: VirtualLoopbackConfiguration, allowPermissionRequest: Bool = true) {
        guard !state.isActive else { return }
        result = nil; lastError = nil; state = .preparing
        generation = UUID(); let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try self.check(token)
                try configuration.validate(devices: AudioDeviceCatalog.devices())
                guard !allowPermissionRequest || Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                    throw VoiceBridgeError.configuration("The app must include its microphone permission description.")
                }
                self.armTimeout(seconds: 30, token: token)
                let granted: Bool
                switch DiagnosticAuthorizationDecision.evaluate(AVCaptureDevice.authorizationStatus(for: .audio), allowPermissionRequest: allowPermissionRequest) {
                case .approved: granted = true
                case .request: granted = await AVCaptureDevice.requestAccess(for: .audio)
                case .rejected:
                    if !allowPermissionRequest {
                        throw VoiceBridgeError.configuration("Diagnostic requires existing microphone authorization; this run cannot request permission.")
                    }
                    granted = false
                }
                try self.check(token)
                guard granted else { throw VoiceBridgeError.microphoneDenied }
                try configuration.validate(devices: AudioDeviceCatalog.devices())
                self.armTimeout(seconds: 15, token: token)
                let pair = [DiagnosticBus(device: configuration.twoChannelDevice), DiagnosticBus(device: configuration.sixteenChannelDevice)]
                self.buses = pair // Own partially started engines, so every thrown error cleans them up.
                for bus in pair {
                    try bus.start { [weak self] message in self?.fail(message, token: token) }
                }
                let baseline = try await self.collect(seconds: 0.6, token: token)
                guard baseline.allSatisfy({ LoopbackClassifier.rms($0) <= 0.0005 }) else {
                    throw VoiceBridgeError.route("A selected bus already carries audio. Close other audio apps and retry.")
                }
                self.state = .testingTwoChannel
                let first = try await self.phase(index: 0, frequency: 997, token: token)
                // Clear the first tone and establish quiet before reversing the route.
                let settled = try await self.collect(seconds: 0.6, token: token)
                guard settled.suffix(2).allSatisfy({ LoopbackClassifier.rms(Array($0.suffix(4800))) <= 0.0005 }) else {
                    throw VoiceBridgeError.route("The first diagnostic tone did not clear from the buses.")
                }
                self.state = .testingSixteenChannel
                let second = try await self.phase(index: 1, frequency: 1499, token: token)
                try self.check(token)
                let report = VirtualLoopbackReport(twoChannelDevice: pair[0].device, sixteenChannelDevice: pair[1].device,
                    twoChannelInputSampleRate: pair[0].inputRate, twoChannelOutputSampleRate: pair[0].outputRate,
                    sixteenChannelInputSampleRate: pair[1].inputRate, sixteenChannelOutputSampleRate: pair[1].outputRate,
                    twoChannel: first, sixteenChannel: second)
                self.generation = UUID(); self.cleanup(); self.task = nil
                self.result = report
                self.state = .completed
            } catch is CancellationError {
                // Stop or timeout already owns cleanup and state; late permission callbacks cannot restart.
            } catch { self.fail(error.localizedDescription, token: token) }
        }
    }
    public func stop() {
        generation = UUID(); task?.cancel(); task = nil
        cleanup(); state = .idle
    }
    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        generation = UUID(); task?.cancel(); task = nil; cleanup()
        lastError = message; state = .failed
    }
    private func cleanup() {
        timeout?.cancel(); timeout = nil
        buses.forEach { $0.stop() }; buses.removeAll()
    }
    private func armTimeout(seconds: Int, token: UUID) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.fail("Diagnostic timed out and all audio engines were stopped.", token: token)
        }
    }
    private func check(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
    }
    private func phase(index: Int, frequency: Double, token: UUID) async throws -> VirtualLoopbackMetrics {
        for bus in buses { _ = try bus.capture.drain() }
        try buses[index].playTone(frequency: frequency)
        let captured = try await collect(seconds: 2, token: token)
        buses[index].stopTone()
        // Use one full second after initial scheduling and converter latency; arbitrary phase is accepted.
        let own = Array(captured[index].suffix(24_000))
        let other = Array(captured[1 - index].suffix(24_000))
        return LoopbackClassifier.measure(own: own, other: other, frequency: frequency, capturedFrames: captured[index].count)
    }
    private func collect(seconds: Double, token: UUID) async throws -> [[Float]] {
        var samples = [[Float](), [Float]()]
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        repeat {
            try check(token)
            for (index, bus) in buses.enumerated() {
                try bus.verify()
                for data in try bus.capture.drain() {
                    let chunk = try PCM16.floats(data)
                    guard samples[index].count + chunk.count <= 72_000 else { throw VoiceBridgeError.bufferOverflow }
                    samples[index].append(contentsOf: chunk)
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < end
        return samples
    }
}

/// Pure classifier. Fixed one-second window, two different phase frequencies, gain and isolation checks.
enum LoopbackClassifier {
    static let amplitude = 0.015
    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { return .infinity }
        return sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
    static func measure(own: [Float], other: [Float], frequency: Double, capturedFrames: Int? = nil) -> VirtualLoopbackMetrics {
        let ownRMS = rms(own); let otherRMS = rms(other)
        var sine = 0.0; var cosine = 0.0
        for (index, sample) in own.enumerated() {
            let phase = Double(index) * 2 * .pi * frequency / 24_000
            sine += Double(sample) * sin(phase); cosine += Double(sample) * cos(phase)
        }
        let coherentRMS = own.isEmpty ? 0 : hypot(sine, cosine) * sqrt(2) / Double(own.count)
        let correlation = ownRMS > 0 ? min(1, coherentRMS / ownRMS) : 0
        let gain = coherentRMS / (amplitude / sqrt(2))
        let ratio = ownRMS > 0 ? otherRMS / ownRMS : .infinity
        let passed = own.count == 24_000 && other.count == 24_000 && ownRMS.isFinite && otherRMS.isFinite
            && correlation >= 0.98 && gain >= 0.8 && gain <= 1.2 && ratio <= 0.03 && otherRMS <= 0.0005
        return VirtualLoopbackMetrics(ownRMS: ownRMS, otherRMS: otherRMS, correlation: correlation,
                                      gain: gain, leakageRatio: ratio, analyzedFrames: own.count,
                                      capturedFrames: capturedFrames ?? own.count, captureSampleRate: 24_000, passed: passed)
    }
}

/// An input-only engine and a separate output-only engine, both pinned to a single primary virtual device.
@MainActor private final class DiagnosticBus {
    let device: AudioDevice
    let capture = PCMQueue()
    private let input = AVAudioEngine()
    private let output = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let watch = AudioRouteWatch()
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var hardwareInputFormat: AVAudioFormat?
    private var hardwareOutputFormat: AVAudioFormat?
    private var tapped = false
    private var notifications: [NSObjectProtocol] = []
    private var notificationLifetime = AudioRouteNotificationLifetime()
    var inputRate: Double { inputFormat?.sampleRate ?? 0 }
    var outputRate: Double { outputFormat?.sampleRate ?? 0 }
    init(device: AudioDevice) { self.device = device }
    func start(changed: @escaping @MainActor @Sendable (String) -> Void) throws {
        let token = notificationLifetime.begin()
        // Pin every engine I/O node, including its unused side, to the same virtual device.
        // A graph may not silently initialize its unused side on a physical default device.
        try bind(input.inputNode.audioUnit); try bind(input.outputNode.audioUnit)
        try bind(output.inputNode.audioUnit); try bind(output.outputNode.audioUnit)
        // CurrentDevice changes hardware routing, but AVAudioEngine may retain the default
        // microphone's mono client format and speakers' stereo client format until configured.
        let hardwareSource = input.inputNode.inputFormat(forBus: 0)
        let hardwareSink = output.outputNode.outputFormat(forBus: 0)
        let plan = try DiagnosticFormatPolicy.plan(device: device, hardwareSource: hardwareSource, hardwareSink: hardwareSink,
            clientSource: input.inputNode.outputFormat(forBus: 0), clientSink: output.outputNode.inputFormat(forBus: 0))
        let source = plan.source; let sink = plan.sink
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: pcm) else {
            throw DiagnosticFormatPolicy.failure(device: device, stage: "PCM converter creation", hardwareSource: hardwareSource,
                hardwareSink: hardwareSink, clientSource: source, clientSink: sink)
        }
        inputFormat = source; outputFormat = sink
        hardwareInputFormat = hardwareSource; hardwareOutputFormat = hardwareSink
        let processor = CaptureConverter(converter: converter, target: pcm, queue: capture, firstPairInput: true)
        input.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source, block: AudioCallbackBridge.capture(processor))
        tapped = true
        output.attach(player)
        output.connect(player, to: output.mainMixerNode, format: sink)
        output.connect(output.mainMixerNode, to: output.outputNode, format: sink)
        try DiagnosticFormatPolicy.validateConfigured(device: device, plan: plan, hardwareSource: hardwareSource,
            hardwareSink: hardwareSink, clientSource: input.inputNode.outputFormat(forBus: 0),
            clientSink: output.outputNode.inputFormat(forBus: 0))
        try verify(stage: "before engine startup", requireRunning: false)
        try watch.start(input: device.id, output: device.id) { [weak self] event in self?.revalidate(event: event, token: token, changed: changed) }
        for (role, engine) in [("input", input), ("output", output)] {
            notifications.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.revalidate(event: "\(role) AVAudioEngineConfigurationChange", token: token, changed: changed) }
                })
        }
        input.prepare(); output.prepare()
        try output.start(); try input.start()
        try verify(stage: "after engine startup", requireRunning: true)
        notificationLifetime.activate(token)
    }
    private func revalidate(event: String, token: UUID, changed: @MainActor @Sendable (String) -> Void) {
        guard notificationLifetime.accepts(token) else { return }
        do { try verify(stage: "notification \(event)", requireRunning: true) }
        catch { changed(error.localizedDescription) }
    }
    private func bind(_ unit: AudioUnit?) throws {
        guard let unit else { throw VoiceBridgeError.route("No routable diagnostic audio unit.") }
        var id = device.id
        try AudioDeviceCatalog.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<UInt32>.size)))
        guard try current(unit) == device.id else { throw VoiceBridgeError.route("Diagnostic device binding failed.") }
    }
    private func current(_ unit: AudioUnit?) throws -> UInt32 {
        guard let unit else { throw VoiceBridgeError.route("Diagnostic audio unit disappeared.") }
        var id: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        try AudioDeviceCatalog.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &id, &size)); return id
    }
    func verify(stage: String = "capture collection", requireRunning: Bool = true) throws {
        let context = "\(device.name) [\(device.uid)] during \(stage)"
        for (property, unit) in [("input engine input device ID", input.inputNode.audioUnit),
            ("input engine unused output device ID", input.outputNode.audioUnit),
            ("output engine unused input device ID", output.inputNode.audioUnit),
            ("output engine output device ID", output.outputNode.audioUnit)] {
            let actual = try AudioRouteIntegrity.query(property: property, context: context) { try current(unit) }
            try AudioRouteIntegrity.equal(device.id, actual, property: property, context: context)
        }
        let uid = try AudioRouteIntegrity.query(property: "device UID", context: context) {
            try AudioDeviceCatalog.string(device.id, kAudioDevicePropertyDeviceUID)
        }
        try AudioRouteIntegrity.equal(device.uid, uid, property: "device UID", context: context)
        for (property, selector, expected) in [("device alive", kAudioDevicePropertyDeviceIsAlive, UInt32(1)),
            ("virtual transport", kAudioDevicePropertyTransportType, kAudioDeviceTransportTypeVirtual)] {
            let actual = try AudioRouteIntegrity.query(property: property, context: context) { try AudioDeviceCatalog.scalar(device.id, selector) }
            try AudioRouteIntegrity.equal(expected, actual, property: property, context: context)
        }
        guard let hardwareInputFormat, let inputFormat, let hardwareOutputFormat, let outputFormat else {
            throw VoiceBridgeError.route("\(context): configured format snapshots are unavailable.")
        }
        let expected = AudioRouteIntegrity.Engines(inputHardware: hardwareInputFormat, inputClient: inputFormat,
            outputHardware: hardwareOutputFormat, outputClient: outputFormat, inputRunning: true, outputRunning: true)
        let actual = AudioRouteIntegrity.Engines(inputHardware: input.inputNode.inputFormat(forBus: 0),
            inputClient: input.inputNode.outputFormat(forBus: 0), outputHardware: output.outputNode.outputFormat(forBus: 0),
            outputClient: output.outputNode.inputFormat(forBus: 0), inputRunning: input.isRunning, outputRunning: output.isRunning)
        try actual.validate(expected: expected, requireRunning: requireRunning, context: context)
        try watch.verify(context: context)
    }
    func playTone(frequency: Double) throws {
        guard let format = outputFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 2.4)),
              let channels = buffer.floatChannelData else { throw VoiceBridgeError.route("Cannot allocate virtual test waveform.") }
        buffer.frameLength = buffer.frameCapacity
        let count = Int(format.channelCount); let stride = format.isInterleaved ? count : 1
        for channel in 0..<count {
            let destination = format.isInterleaved ? channels[0].advanced(by: channel) : channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                let ramp = min(1, Double(frame) / (format.sampleRate * 0.02))
                destination[frame * stride] = channel < 2
                    ? Float(LoopbackClassifier.amplitude * ramp * sin(2 * .pi * frequency * Double(frame) / format.sampleRate)) : 0
            }
        }
        player.scheduleBuffer(buffer); player.play()
    }
    func stopTone() { player.stop() }
    func stop() {
        notificationLifetime.stop()
        watch.stop(); notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        capture.close()
        if tapped { input.inputNode.removeTap(onBus: 0); tapped = false }
        player.stop(); input.stop(); output.stop(); input.reset(); output.reset()
        inputFormat = nil; outputFormat = nil
        hardwareInputFormat = nil; hardwareOutputFormat = nil
    }
}
