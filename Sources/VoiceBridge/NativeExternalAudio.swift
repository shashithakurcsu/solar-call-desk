@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import HALAudioCore
import Foundation

/// App-owned directional AUHALs have no AVAudioEngine default-device routing policy.
/// Audio threads run only the C callbacks; conversion and Foundation allocation occur off RT.
@MainActor final class NativeExternalAudio {
    let capture: PCMQueue
    var onDrained: (() -> Void)?
    private var source: AudioUnit?
    private var sink: AudioUnit?
    private var sourceInitialized = false
    private var sinkInitialized = false
    private var sourceStarted = false
    private var sinkStarted = false
    private var sessionUsed = false
    private var core: OpaquePointer?
    private var worker: HALCaptureWorker?
    private let watch = AudioRouteWatch()
    private var lifetime = AudioRouteNotificationLifetime()
    private var configuration: VoiceBridgeConfiguration?
    private var inputHardware: HALStreamFormat?
    private var outputHardware: HALStreamFormat?
    private var inputClient: HALStreamFormat?
    private var outputClient: HALStreamFormat?
    private var presentation: HALPresentation?
    private var progress = PlaybackProgress()
    private var generation: UInt64 = 1
    private var itemID: String?
    private var contentIndex = 0
    private(set) var shutdownError: String?
    private var stoppedTimelineDiagnostics: HALTimelineDiagnostics?
    // Failed HAL shutdown must retain callback storage and units. Never free a live refCon.
    private static var retainedFailures: [(AudioUnit?, AudioUnit?, OpaquePointer?, HALCaptureWorker?)] = []

    init(capture: PCMQueue = PCMQueue()) { self.capture = capture }
    static func requireSafeShutdown() throws {
        guard retainedFailures.isEmpty else { throw VoiceBridgeError.route("A prior native audio shutdown could not be confirmed. Quit and reopen Solar Call Desk before starting again.") }
    }

    func start(_ config: VoiceBridgeConfiguration, routeChanged: @escaping @MainActor @Sendable (String) -> Void) throws {
        try Self.requireSafeShutdown()
        guard !sessionUsed, source == nil, sink == nil, core == nil, configuration == nil, config.mode == .externalBridge else {
            throw VoiceBridgeError.route("Native external audio requires a fresh external session.")
        }
        sessionUsed = true
        let devices = try AudioDeviceCatalog.devices()
        try config.validate(devices: devices)
        guard let selectedInput = devices.first(where: { $0.id == config.inputDeviceID }),
              let selectedOutput = devices.first(where: { $0.id == config.outputDeviceID }) else { throw VoiceBridgeError.route("Selected native devices unavailable.") }
        configuration = config
        let token = lifetime.begin()
        do {
            source = try makeUnit(input: true, id: config.inputDeviceID)
            sink = try makeUnit(input: false, id: config.outputDeviceID)
            guard let source, let sink else { throw VoiceBridgeError.route("Dedicated audio units unavailable.") }
            let sourceASBD = try format(source, scope: kAudioUnitScope_Input, bus: 1)
            let sinkASBD = try format(sink, scope: kAudioUnitScope_Output, bus: 0)
            try AudioRouteIntegrity.equal(UInt32(selectedInput.inputChannels), sourceASBD.mChannelsPerFrame, property: "native input hardware width", context: "Device \(config.inputDeviceID)")
            try AudioRouteIntegrity.equal(UInt32(selectedOutput.outputChannels), sinkASBD.mChannelsPerFrame, property: "native output hardware width", context: "Device \(config.outputDeviceID)")
            try HALStreamFormat.validateNative(sourceASBD, role: "input")
            try HALStreamFormat.validateNative(sinkASBD, role: "output")
            inputHardware = HALStreamFormat(sourceASBD); outputHardware = HALStreamFormat(sinkASBD)
            var sourceClient = HALStreamFormat.floatClient(channels: sourceASBD.mChannelsPerFrame)
            var sinkClient = HALStreamFormat.floatClient(channels: sinkASBD.mChannelsPerFrame)
            try set(source, property: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, bus: 1, value: &sourceClient)
            try set(sink, property: kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, bus: 0, value: &sinkClient)
            var allocateInput: UInt32 = 0
            try set(source, property: kAudioUnitProperty_ShouldAllocateBuffer, scope: kAudioUnitScope_Output, bus: 1, value: &allocateInput)
            inputClient = HALStreamFormat(sourceClient); outputClient = HALStreamFormat(sinkClient)
            let margin = try HALPresentation.read(device: config.outputDeviceID, unit: sink)
            presentation = margin
            guard let allocated = SBHALCreate(sourceASBD.mChannelsPerFrame, sinkASBD.mChannelsPerFrame, 8192, margin.frames) else {
                throw VoiceBridgeError.route("Cannot allocate bounded native audio buffers.")
            }
            core = allocated; generation = SBHALGeneration(allocated)
            SBHALSetCaptureUnit(allocated, source)
            var inputCallback = AURenderCallbackStruct(inputProc: SBHALCaptureCallback, inputProcRefCon: UnsafeMutableRawPointer(allocated))
            var outputCallback = AURenderCallbackStruct(inputProc: SBHALOutputCallback, inputProcRefCon: UnsafeMutableRawPointer(allocated))
            try set(source, property: kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, bus: 0, value: &inputCallback)
            try set(sink, property: kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input, bus: 0, value: &outputCallback)
            worker = try HALCaptureWorker(core: allocated, capture: capture)
            // Baselines precede initialization/start; all notifications require actual drift.
            try watch.start(input: config.inputDeviceID, output: config.outputDeviceID) { [weak self] event in
                guard let self, self.lifetime.accepts(token) else { return }
                do { try self.verify(stage: "notification \(event)") }
                catch { routeChanged(error.localizedDescription) }
            }
            try verify(stage: "before native initialization", requireRunning: false)
            try AudioDeviceCatalog.check(AudioUnitInitialize(source))
            sourceInitialized = true
            try AudioDeviceCatalog.check(AudioUnitInitialize(sink))
            sinkInitialized = true
            try verify(stage: "after native initialization", requireRunning: false)
            worker?.start()
            try AudioDeviceCatalog.check(AudioOutputUnitStart(sink))
            sinkStarted = true
            try AudioDeviceCatalog.check(AudioOutputUnitStart(source))
            sourceStarted = true
            try verify(stage: "after native startup", requireRunning: true)
            lifetime.activate(token)
        } catch {
            let original = error.localizedDescription
            let cleanup = stop()
            throw VoiceBridgeError.route(cleanup.map { "\(original) Cleanup: \($0)" } ?? original)
        }
    }

    func verify(stage: String = "voice route verification", requireRunning: Bool? = nil) throws {
        guard let config = configuration, let source, let sink, let core else { throw VoiceBridgeError.route("Native audio is unavailable.") }
        let context = "Input \(config.inputDeviceID) [\(config.inputDeviceUID ?? "unknown")], output \(config.outputDeviceID) [\(config.outputDeviceUID ?? "unknown")] during \(stage)"
        for (role, unit, id, uid) in [("input", source, config.inputDeviceID, config.inputDeviceUID), ("output", sink, config.outputDeviceID, config.outputDeviceUID)] {
            let actual: UInt32 = try query(unit, property: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0)
            guard actual == id else {
                throw VoiceBridgeError.route("\(context): native \(role) device ID changed; expected \(id), observed \(actual) [\(Self.driftMetadata(actual))]. All audio stopped.")
            }
            try AudioRouteIntegrity.equal(uid, Optional(try AudioDeviceCatalog.string(id, kAudioDevicePropertyDeviceUID)), property: "\(role) UID", context: context)
            try AudioRouteIntegrity.equal(UInt32(1), try AudioDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsAlive), property: "\(role) alive", context: context)
            try AudioRouteIntegrity.equal(UInt32(kAudioDeviceTransportTypeVirtual), try AudioDeviceCatalog.scalar(id, kAudioDevicePropertyTransportType), property: "\(role) virtual transport", context: context)
            let inputEnabled: UInt32 = try query(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1)
            let outputEnabled: UInt32 = try query(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0)
            try AudioRouteIntegrity.equal(role == "input" ? UInt32(1) : 0, inputEnabled, property: "\(role) unit input enabled", context: context)
            try AudioRouteIntegrity.equal(role == "output" ? UInt32(1) : 0, outputEnabled, property: "\(role) unit output enabled", context: context)
            if requireRunning ?? lifetime.isMonitoring {
                let running: UInt32 = try query(unit, property: kAudioOutputUnitProperty_IsRunning, scope: kAudioUnitScope_Global, bus: 0)
                try AudioRouteIntegrity.equal(UInt32(1), running, property: "\(role) native unit running", context: context)
            }
        }
        for (name, expected, actual) in [
            ("input hardware format", inputHardware, HALStreamFormat(try format(source, scope: kAudioUnitScope_Input, bus: 1))),
            ("input client format", inputClient, HALStreamFormat(try format(source, scope: kAudioUnitScope_Output, bus: 1))),
            ("output hardware format", outputHardware, HALStreamFormat(try format(sink, scope: kAudioUnitScope_Output, bus: 0))),
            ("output client format", outputClient, HALStreamFormat(try format(sink, scope: kAudioUnitScope_Input, bus: 0)))
        ] { try AudioRouteIntegrity.equal(expected, Optional(actual), property: name, context: context) }
        try AudioRouteIntegrity.equal(presentation, Optional(try HALPresentation.read(device: config.outputDeviceID, unit: sink)), property: "output presentation bounds", context: context)
        try watch.verify(context: context)
        let failure = SBHALFailure(core)
        guard failure == noErr else { throw VoiceBridgeError.route("\(context): \(failureDescription(failure)). All audio stopped.") }
        refreshPlayback()
    }

    var queuedPlaybackFrames: Int64 { refreshPlayback(); return progress.queuedFrames }

    func play(_ data: Data, item: String, index: Int) throws {
        guard let core else { throw VoiceBridgeError.route("Native playback is unavailable.") }
        refreshPlayback()
        if itemID != item || contentIndex != index {
            guard progress.queuedFrames == 0 else { throw VoiceBridgeError.protocolViolation("Overlapping output audio items.") }
            generation = SBHALInterrupt(core); progress.reset(); itemID = item; contentIndex = index
        }
        guard data.count.isMultiple(of: 2), !data.isEmpty, data.count <= 480_000 else { throw VoiceBridgeError.protocolViolation("Invalid native speech PCM size.") }
        let frames = Int64(data.count / 2)
        try progress.schedule(frames)
        let accepted = data.withUnsafeBytes { SBHALEnqueuePCM16(core, $0.bindMemory(to: UInt8.self).baseAddress!, UInt32(data.count), generation) }
        guard accepted else {
            let failure = SBHALFailure(core)
            throw VoiceBridgeError.route("\(failureDescription(failure)); native speech enqueue rejected. All audio stopped.")
        }
    }
    private func refreshPlayback() {
        guard let core else { return }
        let confirmed = Int64(SBHALCompletedWireFrames(core, generation))
        let previous = progress.queuedFrames
        progress.complete(confirmed - progress.completedFrames)
        if previous > 0 && progress.queuedFrames == 0 { onDrained?() }
    }
    func interrupt() -> (item: String, index: Int, frames: Int64)? {
        refreshPlayback()
        let result = itemID.map { (item: $0, index: contentIndex, frames: progress.playedFrames) }
        if let core { generation = SBHALInterrupt(core) }
        progress.reset(); itemID = nil
        return result
    }
    @discardableResult func stop() -> String? {
        sessionUsed = true
        guard source != nil || sink != nil || core != nil || configuration != nil else { capture.close(); return shutdownError }
        lifetime.stop(); watch.stop(); onDrained = nil
        if let core { SBHALClose(core) }
        var failures: [String] = []
        var safe = true
        // Stop each unit independently, including partial setup failures.
        for (role, unit, initialized) in [("input", source, sourceInitialized), ("output", sink, sinkInitialized)] {
            guard let unit else { continue }
            guard initialized else { continue } // Never started: disposal alone cleans partial setup.
            let status = AudioOutputUnitStop(unit)
            if status != noErr { failures.append("\(role) native stop failed (\(status))"); safe = false }
            do {
                let after: UInt32 = try query(unit, property: kAudioOutputUnitProperty_IsRunning, scope: kAudioUnitScope_Global, bus: 0)
                if after != 0 { failures.append("\(role) native unit still running"); safe = false }
            } catch { failures.append("\(role) shutdown running query failed"); safe = false }
        }
        let retainedWorker = worker
        if worker?.stop() == false { failures.append("Native capture worker cancellation timed out"); safe = false }
        worker = nil // Cancellation handler completion proves conversion can no longer touch core.
        if safe {
            for (role, unit, initialized) in [("input", source, sourceInitialized), ("output", sink, sinkInitialized)] {
                guard let unit, initialized else { continue }
                let status = AudioUnitUninitialize(unit)
                if status != noErr { failures.append("\(role) native uninitialize failed (\(status))"); safe = false }
            }
        }
        if safe {
            if let unit = source {
                let status = AudioComponentInstanceDispose(unit)
                if status == noErr { source = nil } else { failures.append("input native dispose failed (\(status))"); safe = false }
            }
            if let unit = sink {
                let status = AudioComponentInstanceDispose(unit)
                if status == noErr { sink = nil } else { failures.append("output native dispose failed (\(status))"); safe = false }
            }
        }
        stoppedTimelineDiagnostics = timelineDiagnostics()
        if safe, let core {
            if SBHALDestroy(core) {
                self.core = nil
            } else {
                safe = false
            }
        }
        if !safe {
            failures.append("Native callback resources retained because shutdown could not be confirmed")
            Self.retainedFailures.append((source, sink, core, retainedWorker)); source = nil; sink = nil; core = nil
        }
        sourceInitialized = false; sinkInitialized = false; sourceStarted = false; sinkStarted = false
        configuration = nil; inputHardware = nil; outputHardware = nil; inputClient = nil; outputClient = nil
        presentation = nil; progress.reset(); itemID = nil; capture.close()
        shutdownError = failures.isEmpty ? nil : failures.joined(separator: "; ")
        return shutdownError
    }

    private func makeUnit(input: Bool, id: UInt32) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw VoiceBridgeError.route("HAL audio component unavailable.") }
        var unit: AudioUnit?
        try AudioDeviceCatalog.check(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw VoiceBridgeError.route("HAL audio unit unavailable.") }
        // Own immediately, so every later setup error follows the same stop/dispose path.
        if input { source = unit } else { sink = unit }
        var enabled: UInt32 = input ? 1 : 0
        try set(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1, value: &enabled)
        enabled = input ? 0 : 1
        try set(unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0, value: &enabled)
        var selected = id
        try set(unit, property: kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0, value: &selected)
        var maximum: UInt32 = 8192
        try set(unit, property: kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, bus: 0, value: &maximum)
        return unit
    }
    private func format(_ unit: AudioUnit, scope: AudioUnitScope, bus: UInt32) throws -> AudioStreamBasicDescription {
        try query(unit, property: kAudioUnitProperty_StreamFormat, scope: scope, bus: bus)
    }
    private func query<T: BitwiseCopyable>(_ unit: AudioUnit, property: AudioUnitPropertyID, scope: AudioUnitScope, bus: UInt32) throws -> T {
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1); defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioUnitGetProperty(unit, property, scope, bus, value, &size)
        guard status == noErr else { throw VoiceBridgeError.route("Querying native property \(property), scope \(scope), bus \(bus) failed (\(status)).") }
        guard size == MemoryLayout<T>.size else { throw VoiceBridgeError.route("Native audio property \(property) returned size \(size).") }
        return value.pointee
    }
    private func set<T: BitwiseCopyable>(_ unit: AudioUnit, property: AudioUnitPropertyID, scope: AudioUnitScope, bus: UInt32, value: inout T) throws {
        try withUnsafePointer(to: &value) { try AudioDeviceCatalog.check(AudioUnitSetProperty(unit, property, scope, bus, $0, UInt32(MemoryLayout<T>.size))) }
    }
    private static func driftMetadata(_ id: UInt32) -> String {
        let uid = ((try? AudioDeviceCatalog.string(id, kAudioDevicePropertyDeviceUID)) ?? "unavailable").prefix(160)
        let name = ((try? AudioDeviceCatalog.string(id, kAudioObjectPropertyName)) ?? "unavailable").prefix(160)
        let transport = (try? AudioDeviceCatalog.scalar(id, kAudioDevicePropertyTransportType)).map(String.init) ?? "unavailable"
        return "UID=\(uid), name=\(name), transport=\(transport)"
    }
    nonisolated static func callbackFailure(_ status: OSStatus) -> String {
        switch status {
        case -70001: "Native audio buffer was rejected"
        case -70002: "Native audio queue exceeded its fixed bound"
        case -70003: "Native output timestamp could not be used safely"
        default: "Native input rendering failed"
        }
    }
    func timelineDiagnostics() -> HALTimelineDiagnostics {
        guard let core else { return stoppedTimelineDiagnostics ?? HALTimelineDiagnostics(recoveredIdleDiscontinuities: 0, firstRecoveredEvent: nil, firstFault: nil) }
        let recovered = SBHALRecoveredIdleDiscontinuities(core)
        var first = SBHALTimelineEvent(), fault = SBHALTimelineEvent()
        return HALTimelineDiagnostics(recoveredIdleDiscontinuities: recovered,
            firstRecoveredEvent: SBHALGetFirstIdleRecovery(core, &first) ? Self.describeTimeline(first) : nil,
            firstFault: SBHALGetTimelineFault(core, &fault) ? Self.describeTimeline(fault) : nil)
    }
    private func failureDescription(_ status: OSStatus) -> String {
        let detail = status == -70003 ? timelineDiagnostics().firstFault : nil
        return "\(Self.callbackFailure(status)) (\(status))" + (detail.map { ": \($0)" } ?? "")
    }
    nonisolated static func describeTimeline(_ event: SBHALTimelineEvent) -> String {
        let reason: String
        switch event.reason {
        case 1: reason = "missing timestamp"
        case 2: reason = "sample-time validity flag missing"
        case 3: reason = "nonfinite sample time"
        case 4: reason = "forward sample-time gap"
        case 5: reason = "backward sample-time reset"
        case 6: reason = "overlapping or repeated sample-time slice"
        default: reason = "unknown timestamp event"
        }
        let previous = event.hasPrevious != 0 ? String(event.previousSampleTime) : "unset"
        let expected = event.hasPrevious != 0 ? String(event.expectedSampleTime) : "unset"
        return "\(reason); callback=\(event.callbackOrdinal), generation=\(event.generation), timestampFlags=0x\(String(event.timestampFlags, radix: 16)), actionFlags=0x\(String(event.actionFlags, radix: 16)), previous=\(previous)/\(event.previousFrames)frames, expected=\(expected), actual=\(event.actualSampleTime), delta=\(event.delta), requested=\(event.frames)frames, emittedUnconfirmed=\(event.emittedUnconfirmedNativeFrames), partial=\(event.partialNativeFrames), queued=\(event.queuedNativeFrames), markers=\(event.pendingMarkers), held=\(event.heldMarkers), previousSilent=\(event.previousSliceWasSilent != 0)"
    }
}

struct HALTimelineDiagnostics: Sendable, Equatable {
    let recoveredIdleDiscontinuities: UInt64
    let firstRecoveredEvent: String?
    let firstFault: String?
}

struct HALStreamFormat: Equatable, CustomStringConvertible {
    let rate: Double; let format: UInt32; let flags: UInt32; let bytesPerPacket: UInt32
    let framesPerPacket: UInt32; let bytesPerFrame: UInt32; let channels: UInt32; let bits: UInt32
    init(_ value: AudioStreamBasicDescription) {
        rate = value.mSampleRate; format = value.mFormatID; flags = value.mFormatFlags
        bytesPerPacket = value.mBytesPerPacket; framesPerPacket = value.mFramesPerPacket
        bytesPerFrame = value.mBytesPerFrame; channels = value.mChannelsPerFrame; bits = value.mBitsPerChannel
    }
    var description: String { "\(channels)ch/\(rate)Hz/format\(format)/flags\(flags)/\(bits)bits/\(bytesPerFrame)bytes" }
    static func validateNative(_ value: AudioStreamBasicDescription, role: String) throws {
        guard value.mSampleRate == 48_000, value.mChannelsPerFrame >= 2, value.mChannelsPerFrame <= 64,
              value.mFormatID == kAudioFormatLinearPCM else {
            throw VoiceBridgeError.route("Native external \(role) requires a 48 kHz PCM virtual device with 2–64 channels; observed \(HALStreamFormat(value)).")
        }
    }
    static func floatClient(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
}

/// Readable device/stream/AU latency only. PresentationLatency is write-only and is never queried.
struct HALPresentation: Equatable, CustomStringConvertible {
    let buffer: UInt32; let safety: UInt32; let deviceLatency: UInt32; let streamLatency: UInt32; let unitLatency: Double
    var frames: UInt32 { buffer + safety + deviceLatency + streamLatency + UInt32(ceil(unitLatency * 48_000)) + buffer }
    var description: String { "buffer=\(buffer), safety=\(safety), device=\(deviceLatency), stream=\(streamLatency), AU=\(unitLatency)s, holdback=\(frames)frames" }
    static func validated(buffer: UInt32, safety: UInt32, deviceLatency: UInt32, streamLatency: UInt32, unitLatency: Double) throws -> HALPresentation {
        guard buffer > 0, buffer <= 8192, safety <= 8192, deviceLatency <= 8192, streamLatency <= 8192,
              unitLatency.isFinite, unitLatency >= 0, unitLatency <= 0.1 else { throw VoiceBridgeError.route("Native presentation latency exceeds its bound.") }
        let result = HALPresentation(buffer: buffer, safety: safety, deviceLatency: deviceLatency, streamLatency: streamLatency, unitLatency: unitLatency)
        guard result.frames <= 48_000 else { throw VoiceBridgeError.route("Native output presentation holdback exceeds one second.") }
        return result
    }
    static func read(device: UInt32, unit: AudioUnit) throws -> HALPresentation {
        let buffer = try scalar(device, selector: kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal)
        let safety = try scalar(device, selector: kAudioDevicePropertySafetyOffset, scope: kAudioDevicePropertyScopeOutput)
        let latency = try scalar(device, selector: kAudioDevicePropertyLatency, scope: kAudioDevicePropertyScopeOutput)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try AudioDeviceCatalog.check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size))
        guard size > 0, size <= 256, size.isMultiple(of: 4) else { throw VoiceBridgeError.route("Invalid output stream list size \(size).") }
        var streams = [UInt32](repeating: 0, count: Int(size / 4))
        try streams.withUnsafeMutableBytes { try AudioDeviceCatalog.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)) }
        let streamLatency = try streams.map { try scalar($0, selector: kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal) }.max() ?? 0
        var unitLatency = 0.0; size = 8
        try AudioDeviceCatalog.check(AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &unitLatency, &size))
        return try validated(buffer: buffer, safety: safety, deviceLatency: latency, streamLatency: streamLatency, unitLatency: unitLatency)
    }
    private static func scalar(_ device: UInt32, selector: UInt32, scope: UInt32) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size: UInt32 = 4
        try AudioDeviceCatalog.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value))
        guard size == 4 else { throw VoiceBridgeError.route("Invalid latency property size.") }
        return value
    }
}

/// Immutable configuration and queue confinement synchronize the worker's reusable PCM buffer.
/// Its context remains alive until stop() has joined the queue and the HAL units are disposed.
private final class HALCaptureWorker: @unchecked Sendable {
    private let core: OpaquePointer
    private let capture: PCMQueue
    private let buffer: AVAudioPCMBuffer
    private let processor: CaptureConverter
    private let queue = DispatchQueue(label: "SolarCallDesk.HALCaptureConversion")
    private let cancellation = DispatchGroup()
    private var timer: DispatchSourceTimer? // Accessed only by start/stop on MainActor.
    init(core: OpaquePointer, capture: PCMQueue) throws {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096) else {
            throw VoiceBridgeError.route("Native capture conversion unavailable.")
        }
        self.core = core; self.capture = capture; self.buffer = buffer
        processor = CaptureConverter(converter: converter, target: target, queue: capture)
    }
    @MainActor func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        cancellation.enter()
        let cancellation = cancellation
        timer.setCancelHandler { @Sendable in cancellation.leave() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { @Sendable [self] in
            guard let samples = buffer.floatChannelData?[0] else { capture.fail(.route("Native capture buffer unavailable.")); return }
            for _ in 0..<24 {
                let frames = SBHALReadCapture(core, samples, 4096)
                guard frames > 0 else { break }
                buffer.frameLength = frames
                processor.consume(buffer)
            }
        }
        self.timer = timer; timer.resume()
    }
    @MainActor func stop() -> Bool {
        guard let timer else { return true }
        timer.cancel(); self.timer = nil
        return cancellation.wait(timeout: .now() + .seconds(1)) == .success
    }
}
