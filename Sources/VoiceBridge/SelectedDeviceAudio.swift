@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

/// Two independent engines. Only the selected input tap reaches the socket; only selected output receives speech.
/// The input is never connected to the output mixer. Creating/starting this object is exclusive to explicit Start.
@MainActor final class SelectedDeviceAudio: VoiceAudioEndpoint {
    private lazy var inputEngine = AVAudioEngine()
    private lazy var outputEngine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private var rehearsalStarted = false
    private var native: NativeExternalAudio?
    private var sessionUsed = false
    let capture = PCMQueue()
    private var tapInstalled = false
    private var notifications: [NSObjectProtocol] = []
    private let watch = AudioRouteWatch()
    private var notificationLifetime = AudioRouteNotificationLifetime()
    private var inputTransport: UInt32?
    private var outputTransport: UInt32?
    private var inputID: UInt32 = 0
    private var outputID: UInt32 = 0
    private var bindingPlan: [AudioEngineBindingTarget] = []
    private var inputUID: String?
    private var outputUID: String?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var hardwareInputFormat: AVAudioFormat?
    private var hardwareOutputFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var progress = PlaybackProgress()
    private var playbackGeneration = UUID()
    private var itemID: String?
    private var contentIndex = 0
    var onDrained: (() -> Void)? { didSet { native?.onDrained = onDrained } }

    func start(_ config: VoiceBridgeConfiguration, routeChanged: @escaping @MainActor @Sendable (String) -> Void) throws {
        try NativeExternalAudio.requireSafeShutdown()
        guard !sessionUsed else { throw VoiceBridgeError.route("Audio objects require a fresh instance for each session.") }
        sessionUsed = true
        if config.mode == .externalBridge {
            let native = NativeExternalAudio(capture: capture)
            self.native = native; native.onDrained = onDrained
            try native.start(config, routeChanged: routeChanged)
            return
        }
        rehearsalStarted = true
        let token = notificationLifetime.begin()
        inputID = config.inputDeviceID; outputID = config.outputDeviceID
        inputUID = config.inputDeviceUID; outputUID = config.outputDeviceUID
        bindingPlan = AudioEngineBindingPlan.make(mode: config.mode, inputID: inputID, outputID: outputID)
        try AudioEngineBindingPlan.configure(bindingPlan, resolve: ioNode) { node, id in try setDevice(node.audioUnit, id: id) }
        let input = inputEngine.inputNode
        let output = outputEngine.outputNode
        inputTransport = try AudioDeviceCatalog.scalar(inputID, kAudioDevicePropertyTransportType)
        outputTransport = try AudioDeviceCatalog.scalar(outputID, kAudioDevicePropertyTransportType)
        try verifyDevices()
        let hardwareInput = input.inputFormat(forBus: 0)
        let hardwareOutput = output.outputFormat(forBus: 0)
        let format = try AudioClientFormat.make(hardware: hardwareInput)
        let outputClient = try AudioClientFormat.make(hardware: hardwareOutput)
        // External multichannel buses carry the call on channels 1–2. Discrete 16ch layouts do not
        // reliably support automatic mono conversion; explicitly select/average this pair first.
        let firstPairInput = config.mode == .externalBridge && format.channelCount > 2
        let converterInput: AVAudioFormat
        if firstPairInput {
            guard format.commonFormat == .pcmFormatFloat32,
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                           channels: 1, interleaved: false) else {
                throw VoiceBridgeError.route("External multichannel input requires a usable Float32 first channel pair.")
            }
            converterInput = mono
        } else { converterInput = format }
        guard format.sampleRate > 0, format.channelCount > 0,
              hardwareOutput.sampleRate > 0, hardwareOutput.channelCount > 0,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: converterInput, to: pcm) else {
            throw VoiceBridgeError.route("Selected devices do not provide usable audio formats.")
        }
        let speech = try AudioClientFormat.make(hardware: hardwareOutput, sampleRate: 24_000)
        inputFormat = format; outputFormat = outputClient; playbackFormat = speech
        hardwareInputFormat = hardwareInput; hardwareOutputFormat = hardwareOutput
        converter.downmix = true
        let processor = CaptureConverter(converter: converter, target: pcm, queue: capture, firstPairInput: firstPairInput)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: AudioCallbackBridge.capture(processor))
        tapInstalled = true
        outputEngine.attach(player)
        outputEngine.connect(player, to: outputEngine.mainMixerNode, format: speech)
        outputEngine.connect(outputEngine.mainMixerNode, to: output, format: outputClient)
        // There is deliberately no input->mixer connection, including in rehearsal mode.
        try verifyDevices()
        try watch.start(input: inputID, output: outputID) { [weak self] event in
            self?.revalidate(event: event, token: token, routeChanged: routeChanged)
        }
        for (role, engine) in [("input", inputEngine), ("output", outputEngine)] {
            notifications.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                          object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.revalidate(event: "\(role) AVAudioEngineConfigurationChange", token: token, routeChanged: routeChanged) }
            })
        }
        outputEngine.prepare(); inputEngine.prepare()
        try outputEngine.start()
        try inputEngine.start()
        try verifyDevices(stage: "after engine startup", requireRunning: true)
        notificationLifetime.activate(token)
    }
    private func revalidate(event: String, token: UUID, routeChanged: @MainActor @Sendable (String) -> Void) {
        guard notificationLifetime.accepts(token) else { return }
        do { try verifyDevices(stage: "notification \(event)", requireRunning: true) }
        catch { routeChanged(error.localizedDescription) }
    }
    func verifyDevices(stage: String = "voice route verification", requireRunning: Bool? = nil) throws {
        if let native { try native.verify(stage: stage, requireRunning: requireRunning); return }
        let context = "Input \(inputID) [\(inputUID ?? "unknown")], output \(outputID) [\(outputUID ?? "unknown")] during \(stage)"
        for (role, id, expectedUID, expectedTransport) in [("input", inputID, inputUID, inputTransport), ("output", outputID, outputUID, outputTransport)] {
            let actualUID = try AudioRouteIntegrity.query(property: "\(role) UID", context: context) { try AudioDeviceCatalog.string(id, kAudioDevicePropertyDeviceUID) }
            try AudioRouteIntegrity.equal(expectedUID, Optional(actualUID), property: "\(role) UID", context: context)
            let alive = try AudioRouteIntegrity.query(property: "\(role) alive", context: context) { try AudioDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsAlive) }
            try AudioRouteIntegrity.equal(UInt32(1), alive, property: "\(role) alive", context: context)
            let transport = try AudioRouteIntegrity.query(property: "\(role) transport", context: context) { try AudioDeviceCatalog.scalar(id, kAudioDevicePropertyTransportType) }
            try AudioRouteIntegrity.equal(expectedTransport, Optional(transport), property: "\(role) transport", context: context)
        }
        // Resolve all planned halves before reading any IDs, so a lazy lookup cannot reset
        // an already-verified half later in this verification pass.
        let nodes = bindingPlan.map { ($0, ioNode($0.endpoint)) }
        var observed: [AudioEngineEndpoint: UInt32] = [:]
        for (target, node) in nodes {
            observed[target.endpoint] = try AudioRouteIntegrity.query(property: target.endpoint.description, context: context) { try currentDevice(node.audioUnit) }
        }
        try AudioEngineBindingPlan.validate(bindingPlan, observed: observed, context: context)
        if let inputFormat, let outputFormat, let hardwareInputFormat, let hardwareOutputFormat {
            let expected = AudioRouteIntegrity.Engines(inputHardware: hardwareInputFormat, inputClient: inputFormat,
                outputHardware: hardwareOutputFormat, outputClient: outputFormat, inputRunning: true, outputRunning: true)
            let actual = AudioRouteIntegrity.Engines(inputHardware: inputEngine.inputNode.inputFormat(forBus: 0),
                inputClient: inputEngine.inputNode.outputFormat(forBus: 0), outputHardware: outputEngine.outputNode.outputFormat(forBus: 0),
                outputClient: outputEngine.outputNode.inputFormat(forBus: 0), inputRunning: inputEngine.isRunning, outputRunning: outputEngine.isRunning)
            try actual.validate(expected: expected, requireRunning: requireRunning ?? notificationLifetime.isMonitoring, context: context)
        }
        try watch.verify(context: context)
    }

    private func ioNode(_ endpoint: AudioEngineEndpoint) -> AVAudioIONode {
        switch endpoint {
        case .inputEngineInput: inputEngine.inputNode
        case .inputEngineOutput: inputEngine.outputNode
        case .outputEngineInput: outputEngine.inputNode
        case .outputEngineOutput: outputEngine.outputNode
        }
    }

    private func setDevice(_ unit: AudioUnit?, id: UInt32) throws {
        guard let unit else { throw VoiceBridgeError.route("Selected device has no routable audio unit.") }
        var id = id
        try AudioDeviceCatalog.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                          kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<UInt32>.size)))
        guard try currentDevice(unit) == id else { throw VoiceBridgeError.route("Selected audio device could not be bound.") }
    }
    private func currentDevice(_ unit: AudioUnit?) throws -> UInt32 {
        guard let unit else { throw VoiceBridgeError.route("Audio unit is unavailable.") }
        var id: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        try AudioDeviceCatalog.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                          kAudioUnitScope_Global, 0, &id, &size))
        return id
    }

    var queuedPlaybackFrames: Int64 { native?.queuedPlaybackFrames ?? progress.queuedFrames }

    func play(_ data: Data, item: String, index: Int) throws {
        if let native { try native.play(data, item: item, index: index); return }
        guard let playbackFormat else { throw VoiceBridgeError.route("Playback is not ready.") }
        let frames = Int64(data.count / 2)
        if itemID != item || contentIndex != index {
            guard progress.queuedFrames == 0 else { throw VoiceBridgeError.protocolViolation("Overlapping output audio items.") }
            player.stop(); playbackGeneration = UUID(); progress.reset()
            itemID = item; contentIndex = index
        }
        let buffer = try SpeechPlaybackBuffer.make(data: data, format: playbackFormat)
        try progress.schedule(frames)
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
            completionHandler: AudioCallbackBridge.playback { [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.progress.complete(frames)
                if self.progress.queuedFrames == 0 { self.onDrained?() }
            })
        if !player.isPlaying { player.play() }
    }

    /// Only whole buffers confirmed with dataPlayedBack are counted. Partial chunks are deliberately excluded.
    /// Elapsed player clocks include underrun silence, so they cannot safely measure delivered speech frames.
    func interrupt() -> (item: String, index: Int, frames: Int64)? {
        if let native { return native.interrupt() }
        let played = progress.playedFrames
        let result = itemID.map { (item: $0, index: contentIndex, frames: played) }
        player.stop(); playbackGeneration = UUID(); progress.reset(); itemID = nil
        return result
    }
    @discardableResult func stop() -> String? {
        sessionUsed = true
        if let native {
            let error = native.stop(); self.native = nil; onDrained = nil
            return error
        }
        guard rehearsalStarted else { capture.close(); return nil }
        notificationLifetime.stop()
        watch.stop()
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        capture.close()
        if tapInstalled { inputEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        _ = interrupt()
        inputEngine.stop(); outputEngine.stop(); inputEngine.reset(); outputEngine.reset()
        inputFormat = nil; outputFormat = nil; playbackFormat = nil; onDrained = nil
        hardwareInputFormat = nil; hardwareOutputFormat = nil
        inputTransport = nil; outputTransport = nil
        bindingPlan.removeAll()
        return nil
    }
}

/// The lock serializes converter state and retained packets, including concurrent callback
/// invocations. Configuration is completed before ownership transfers to this processor.
/// No tasks are created for captured chunks.
final class CaptureConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let queue: PCMQueue
    private let lock = NSLock()
    private let firstPairInput: Bool
    // Converter input can outlive a single convert() call. Retain owned packet buffers across callbacks.
    private var retainedInputs: [AVAudioPCMBuffer] = []
    init(converter: AVAudioConverter, target: AVAudioFormat, queue: PCMQueue, firstPairInput: Bool = false) {
        self.converter = converter; self.target = target; self.queue = queue
        self.firstPairInput = firstPairInput
    }
    func consume(_ hardwareInput: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let input: AVAudioPCMBuffer
        if firstPairInput {
            guard let mixed = Self.firstPairMono(hardwareInput) else {
                queue.fail(.route("Cannot select the external input's first channel pair.")); return
            }
            input = mixed
        } else { input = hardwareInput }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate) + 64)
        var offset: AVAudioFrameCount = 0
        var owned: [AVAudioPCMBuffer] = []
        var copyFailed = false
        // Preserve previous owned packets while the converter consumes any retained tail.
        defer { retainedInputs = owned }
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                queue.fail(.route("PCM conversion buffer unavailable.")); return
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, state in
                guard offset < input.frameLength, requested > 0 else { state.pointee = .noDataNow; return nil }
                let frames = min(requested, input.frameLength - offset)
                guard owned.count < 16,
                      let packet = Self.copy(input, offset: offset, frames: frames) else {
                    copyFailed = true; state.pointee = .noDataNow; return nil
                }
                offset += frames; owned.append(packet)
                state.pointee = .haveData
                return packet
            }
            guard error == nil, status != .error, !copyFailed else {
                queue.fail(.route("Audio conversion failed.")); return
            }
            if output.frameLength > 0, let bytes = output.int16ChannelData?[0] {
                queue.push(Data(bytes: bytes, count: Int(output.frameLength) * 2))
            }
            if status == .inputRanDry && offset == input.frameLength { return }
            if status == .endOfStream { queue.fail(.route("Audio converter ended unexpectedly.")); return }
        }
        queue.fail(.route("Audio converter could not drain pending input within its bound."))
    }
    private static func firstPairMono(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.format.commonFormat == .pcmFormatFloat32, source.format.channelCount >= 2,
              let channels = source.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.format.sampleRate,
                                         channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
              let output = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = source.frameLength
        let interleaved = source.format.isInterleaved
        let stride = interleaved ? Int(source.format.channelCount) : 1
        let left = channels[0]
        let right = interleaved ? channels[0].advanced(by: 1) : channels[1]
        for frame in 0..<Int(source.frameLength) {
            output[frame] = (left[frame * stride] + right[frame * stride]) * 0.5
        }
        return mono
    }
    private static func copy(_ source: AVAudioPCMBuffer, offset: AVAudioFrameCount,
                             frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, from.count == to.count else { return nil }
        let start = Int(offset) * bytesPerFrame; let count = Int(frames) * bytesPerFrame
        for index in from.indices {
            guard let input = from[index].mData, let output = to[index].mData,
                  start + count <= Int(from[index].mDataByteSize), count <= Int(to[index].mDataByteSize) else { return nil }
            output.copyMemory(from: input.advanced(by: start), byteCount: count)
        }
        return buffer
    }
}
