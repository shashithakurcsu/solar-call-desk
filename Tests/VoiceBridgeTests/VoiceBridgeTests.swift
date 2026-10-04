import AVFoundation
import Dispatch
#if !VOICE_SELF_CHECK
import XCTest
@testable import VoiceBridge
#else
// Portable CLT-only runner for this machine, where XCTest is unavailable.
// Reuses the same cases with simple assertions; never invokes audio hardware or URLSession.
class XCTestCase {}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool) {
    do { let result = try value(); precondition(result) } catch { preconditionFailure("Unexpected test error") }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool) {
    do { let result = try value(); precondition(!result) } catch { preconditionFailure("Unexpected test error") }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T) {
    do { let left = try a(); let right = try b(); precondition(left == right) }
    catch { preconditionFailure("Unexpected test error") }
}
func XCTAssertEqual(_ a: Float, _ b: Float, accuracy: Float) { precondition(abs(a - b) <= accuracy) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); preconditionFailure("Expected a rejected operation") } catch {}
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw VoiceBridgeError.protocolViolation("Expected a non-nil synthetic test value") }
    return value
}
#endif

final class VoiceBridgeTests: XCTestCase {
    private let devices = [
        AudioDevice(id: 1, name: "Bus A", uid: "virtual-a", inputChannels: 2, outputChannels: 2, isVirtual: true),
        AudioDevice(id: 2, name: "Bus B", uid: "virtual-b", inputChannels: 2, outputChannels: 2, isVirtual: true),
        AudioDevice(id: 3, name: "Microphone", uid: "mic", inputChannels: 1, outputChannels: 0),
        AudioDevice(id: 4, name: "Headphones", uid: "phones", inputChannels: 0, outputChannels: 2)
    ]
    private func configuration(mode: VoiceBridgeMode = .externalBridge) -> VoiceBridgeConfiguration {
        VoiceBridgeConfiguration(inputDeviceID: 1, outputDeviceID: 2, mode: mode, instructions: "Speak briefly.",
                                 externalRoutingAcknowledged: true, inputDeviceUID: "virtual-a", outputDeviceUID: "virtual-b")
    }
    func testIndependentVirtualDevicesWithAcknowledgmentAccepted() throws {
        try configuration().validate(devices: devices)
    }
    func testExternalRouteRejectsFeedbackMissingDevicesPhysicalAndNoAcknowledgment() throws {
        var same = configuration(); same.outputDeviceID = 1; same.outputDeviceUID = "virtual-a"
        XCTAssertThrowsError(try same.validate(devices: devices))
        var missing = configuration(); missing.inputDeviceID = 100
        XCTAssertThrowsError(try missing.validate(devices: devices))
        var physical = configuration(); physical.inputDeviceID = 3; physical.inputDeviceUID = "mic"
        XCTAssertThrowsError(try physical.validate(devices: devices))
        var unacknowledged = configuration(); unacknowledged.externalRoutingAcknowledged = false
        XCTAssertThrowsError(try unacknowledged.validate(devices: devices))
    }
    func testHotplugReusedIDAndUnpinnedIDRejected() {
        var stale = configuration(); stale.inputDeviceUID = "old-device"
        XCTAssertThrowsError(try stale.validate(devices: devices))
        stale.inputDeviceUID = nil
        XCTAssertThrowsError(try stale.validate(devices: devices))
    }
    func testRehearsalSupportsSelectedPhysicalMicAndHeadphones() throws {
        var config = configuration(mode: .rehearsal)
        config.inputDeviceID = 3; config.outputDeviceID = 4
        config.inputDeviceUID = "mic"; config.outputDeviceUID = "phones"
        try config.validate(devices: devices)
    }
    func testSessionJSONAndConfigurationAcknowledgment() throws {
        let event = try RealtimeProtocol.parse(RealtimeProtocol.sessionUpdate(configuration()))
        XCTAssertEqual(event["type"] as? String, "session.update")
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["model"] as? String, "gpt-realtime-2.1")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["name"] as? String, "finish_conversation")
        try RealtimeProtocol.validateAcknowledgedAudio(["session": session])
        var incompatible = session
        incompatible["audio"] = ["input": ["format": ["type": "audio/pcmu"]]]
        XCTAssertThrowsError(try RealtimeProtocol.validateAcknowledgedAudio(["session": incompatible]))
    }
    func testEndpointCannotBeChangedByModel() {
        let url = RealtimeProtocol.endpoint(model: "anything&host=example.invalid")
        XCTAssertEqual(url.host, "api.openai.com")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/v1/realtime")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count, 1)
    }
    func testPCMEndianSignedRangeAndMalformedEvents() throws {
        let values = try PCM16.floats(Data([0, 0, 0, 128, 255, 127]))
        XCTAssertEqual(values[0], 0); XCTAssertEqual(values[1], -1)
        XCTAssertEqual(values[2], Float(32767) / 32768)
        XCTAssertThrowsError(try PCM16.floats(Data([1])))
        XCTAssertThrowsError(try RealtimeProtocol.parse("{}"))
        XCTAssertThrowsError(try RealtimeProtocol.parse("not JSON"))
        XCTAssertThrowsError(try RealtimeProtocol.audio(["delta": "@@"]))
        XCTAssertThrowsError(try RealtimeProtocol.audio(["delta": Data([1]).base64EncodedString()]))
        XCTAssertThrowsError(try RealtimeProtocol.append(Data()))
    }
    func testAppendAndTruncateUsePCMAndPlayedFramesOnly() throws {
        let data = Data([1, 2, 3, 4])
        let appended = try RealtimeProtocol.parse(RealtimeProtocol.append(data))
        XCTAssertEqual(appended["audio"] as? String, data.base64EncodedString())
        let truncated = try RealtimeProtocol.parse(RealtimeProtocol.truncate(itemID: "item", contentIndex: 0, playedFrames: 36_000))
        XCTAssertEqual(truncated["audio_end_ms"] as? Int, 1500)
        let negative = try RealtimeProtocol.parse(RealtimeProtocol.truncate(itemID: "item", contentIndex: 0, playedFrames: -1))
        XCTAssertEqual(negative["audio_end_ms"] as? Int, 0)
    }
    func testQueueBoundsOrderOverflowAndStop() throws {
        let queue = PCMQueue(limit: 8)
        queue.push(Data([1, 2])); queue.push(Data([3, 4]))
        XCTAssertEqual(try queue.drain(), [Data([1, 2]), Data([3, 4])])
        queue.push(Data(repeating: 0, count: 10))
        XCTAssertThrowsError(try queue.drain())
        queue.push(Data([1, 2])); XCTAssertThrowsError(try queue.drain())
        let closed = PCMQueue(); closed.push(Data([1, 2])); closed.close(); closed.push(Data([3, 4]))
        XCTAssertEqual(try closed.drain(), [])
    }
    /// Synthetic buffers only: never opens hardware, requests permission or sends a network request.
    func testMemoryOnlyStereo48kConversionToMonoPCM24k() throws {
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target)); converter.downmix = true
        let queue = PCMQueue()
        let processor = CaptureConverter(converter: converter, target: target, queue: queue)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800))
        input.frameLength = 4800
        for channel in 0..<2 { for frame in 0..<4800 { input.floatChannelData![channel][frame] = 0.25 } }
        processor.consume(input)
        let chunks = try queue.drain()
        XCTAssertFalse(chunks.isEmpty)
        let samples = try PCM16.floats(chunks.reduce(Data(), +))
        // Streaming resamplers retain priming frames from the first buffer. Check the steady-state ratio too.
        XCTAssertTrue((1...2400).contains(samples.count))
        XCTAssertEqual(samples[samples.count / 2], 0.25, accuracy: 0.01)
        processor.consume(input)
        let following = try PCM16.floats(queue.drain().reduce(Data(), +))
        XCTAssertEqual(following[following.count / 2], 0.25, accuracy: 0.01)
        var total = samples.count + following.count
        for _ in 0..<98 {
            processor.consume(input)
            let chunk = try PCM16.floats(queue.drain().reduce(Data(), +))
            XCTAssertFalse(chunk.isEmpty)
            XCTAssertEqual(chunk[chunk.count / 2], 0.25, accuracy: 0.01)
            total += chunk.count
        }
        // Ten seconds: fixed allowance detects drift that a short percentage tolerance could conceal.
        #if VOICE_SELF_CHECK
        print("Synthetic 10-second conversion: \(total) frames; expected 240000; difference \(total - 240_000).")
        #endif
        XCTAssertTrue(abs(total - 240_000) <= 512)
    }
    @MainActor func testIdleAndStopDoNotStartIO() {
        let coordinator = VoiceBridgeCoordinator()
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.state.isActive)
    }
    func testPlaybackUnderrunDoesNotCountUnheardAudioAndBudgetIsBounded() throws {
        var progress = PlaybackProgress()
        try progress.schedule(2400); progress.complete(2400) // 100ms spoken
        // Network gap: no completed speech buffers; elapsed time does not change speech progress.
        XCTAssertEqual(progress.playedFrames, 2400)
        try progress.schedule(12_000) // next 500ms queued; interrupted before completion
        XCTAssertEqual(progress.playedFrames, 2400)
        XCTAssertEqual(progress.queuedFrames, 12_000)
        XCTAssertThrowsError(try progress.schedule(240_000))
        progress.reset()
        XCTAssertEqual(progress.playedFrames, 0); XCTAssertEqual(progress.queuedFrames, 0)
    }
    func testStreamingConversionDoesNotRepeatChunks() throws {
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target)); converter.downmix = true
        let queue = PCMQueue(); let processor = CaptureConverter(converter: converter, target: target, queue: queue)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800)); input.frameLength = 4800
        var converted: [Float] = []
        for chunk in 0..<100 {
            for frame in 0..<4800 {
                let value = -0.8 + Float(chunk * 4800 + frame) * 1.6 / 480_000
                input.floatChannelData![0][frame] = value; input.floatChannelData![1][frame] = value
            }
            processor.consume(input)
            converted += try PCM16.floats(queue.drain().reduce(Data(), +))
        }
        XCTAssertTrue(abs(converted.count - 240_000) <= 512)
        // Every chunk has different ramp values. Repeating a 100ms chunk would introduce a ~0.016 step.
        for frame in 1000..<(converted.count - 1000) {
            let expected = -0.8 + Float(frame) * 1.6 / 240_000
            #if VOICE_SELF_CHECK
            if abs(converted[frame] - expected) > 0.005 {
                FileHandle.standardOutput.write(Data("Ramp mismatch frame \(frame): actual \(converted[frame]), expected \(expected), prior \(converted[frame - 1]); total \(converted.count)\n".utf8))
            }
            #endif
            XCTAssertEqual(converted[frame], expected, accuracy: 0.005)
            XCTAssertTrue(converted[frame] - converted[frame - 1] >= -0.001)
        }
        #if VOICE_SELF_CHECK
        print("Synthetic changing-ramp stream: \(converted.count) frames; no repeated chunk or discontinuity detected.")
        #endif
    }
    func test16ChannelCallerFirstPairWithSilentRemainingChannels() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 16))
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: mono, to: target)); converter.downmix = true
        let queue = PCMQueue(); let processor = CaptureConverter(converter: converter, target: target, queue: queue, firstPairInput: true)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800)); input.frameLength = 4800
        var converted: [Float] = []
        for chunk in 0..<100 {
            for frame in 0..<4800 {
                let ramp = -0.8 + Float(chunk * 4800 + frame) * 1.6 / 480_000
                input.floatChannelData![0][frame] = ramp * 0.6
                input.floatChannelData![1][frame] = ramp * 0.2
                for channel in 2..<16 { input.floatChannelData![channel][frame] = 0 }
            }
            processor.consume(input)
            converted += try PCM16.floats(queue.drain().reduce(Data(), +))
        }
        XCTAssertTrue(abs(converted.count - 240_000) <= 512)
        for frame in 1000..<(converted.count - 1000) {
            let expected = (-0.8 + Float(frame) * 1.6 / 240_000) * 0.4
            #if VOICE_SELF_CHECK
            if abs(converted[frame] - expected) > 0.005 {
                FileHandle.standardOutput.write(Data("16ch mismatch frame \(frame): actual \(converted[frame]), expected \(expected)\n".utf8))
            }
            #endif
            XCTAssertEqual(converted[frame], expected, accuracy: 0.005)
            XCTAssertTrue(converted[frame] - converted[frame - 1] >= -0.001)
        }
        #if VOICE_SELF_CHECK
        print("Synthetic 16ch first-pair stream: \(converted.count) frames; amplitude and continuity preserved.")
        #endif
    }
    func testDiagnosticRejectsMirrorsHardwareStaleIdentityAndMissingAcknowledgment() throws {
        let two = AudioDevice(id: 11, name: "BlackHole 2ch", uid: "BlackHole2ch_UID", inputChannels: 2, outputChannels: 2, isVirtual: true)
        let sixteen = AudioDevice(id: 12, name: "BlackHole 16ch", uid: "BlackHole16ch_UID", inputChannels: 16, outputChannels: 16, isVirtual: true)
        let config = VirtualLoopbackConfiguration(twoChannelDevice: two, sixteenChannelDevice: sixteen, noActiveCallsAcknowledged: true)
        try config.validate(devices: [two, sixteen])
        XCTAssertThrowsError(try VirtualLoopbackConfiguration(twoChannelDevice: two, sixteenChannelDevice: sixteen,
            noActiveCallsAcknowledged: false).validate(devices: [two, sixteen]))
        let mirror = AudioDevice(id: 11, name: "Mirror", uid: "BlackHole2ch_2_UID", inputChannels: 2, outputChannels: 2, isVirtual: true)
        XCTAssertThrowsError(try config.validate(devices: [mirror, sixteen]))
        let physical = AudioDevice(id: 11, name: "Physical", uid: two.uid, inputChannels: 2, outputChannels: 2)
        XCTAssertThrowsError(try config.validate(devices: [physical, sixteen]))
        XCTAssertThrowsError(try config.validate(devices: [sixteen]))
        XCTAssertThrowsError(try VirtualLoopbackConfiguration(twoChannelDevice: two, sixteenChannelDevice: two,
            noActiveCallsAcknowledged: true).validate(devices: [two]))
    }
    func testDiagnosticClassifierRequiresKnownSignalAmplitudeContinuityAndIsolation() {
        let step = 2.0 * Double.pi * 997.0 / 24_000.0
        let tone: [Float] = (0..<24_000).map { frame in Float(0.015 * sin(step * Double(frame) + 1.7)) }
        var seed: UInt64 = 4321
        let noise: [Float] = (0..<24_000).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5) * 0.0001
        }
        let normal = LoopbackClassifier.measure(own: zip(tone, noise).map(+), other: noise, frequency: 997)
        XCTAssertTrue(normal.passed); XCTAssertTrue(normal.correlation >= 0.99)
        XCTAssertTrue(abs(normal.gain - 1) < 0.001)
        XCTAssertFalse(LoopbackClassifier.measure(own: tone.map { $0 * 0.1 }, other: noise, frequency: 997).passed)
        XCTAssertFalse(LoopbackClassifier.measure(own: noise, other: noise, frequency: 997).passed)
        XCTAssertFalse(LoopbackClassifier.measure(own: tone, other: tone.map { $0 * 0.04 }, frequency: 997).passed)
        XCTAssertFalse(LoopbackClassifier.measure(own: tone, other: tone, frequency: 997).passed)
        XCTAssertFalse(LoopbackClassifier.measure(own: tone, other: noise, frequency: 1499).passed)
        var dropout = tone; dropout.replaceSubrange(6000..<12_000, with: repeatElement(Float(0), count: 6000))
        XCTAssertFalse(LoopbackClassifier.measure(own: dropout, other: noise, frequency: 997).passed)
        XCTAssertFalse(LoopbackClassifier.measure(own: Array(tone.prefix(12_000)), other: noise, frequency: 997).passed)
        var invalid = tone; invalid[100] = .nan
        XCTAssertFalse(LoopbackClassifier.measure(own: invalid, other: noise, frequency: 997).passed)
        #if VOICE_SELF_CHECK
        print("Synthetic bus classifier: clean signal correlation \(normal.correlation), gain \(normal.gain); noise, attenuation, dropout, wrong frequency, incomplete windows and 4% cross-bus leakage rejected.")
        #endif
    }
    @MainActor func testDiagnosticConstructionAndStopAreInert() {
        let diagnostic = VirtualLoopbackDiagnostic()
        XCTAssertEqual(diagnostic.state, .idle); XCTAssertFalse(diagnostic.state.isActive)
        XCTAssertNil(diagnostic.result); diagnostic.stop()
        XCTAssertEqual(diagnostic.state, .idle); XCTAssertNil(diagnostic.lastError)
    }
    func testDiagnosticPlansUseHardwareChannelsInsteadOfInheritedMonoAndStereoClients() throws {
        let inheritedSource = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let inheritedSink = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for count: UInt32 in [2, 16] {
            let device = AudioDevice(id: count, name: "BlackHole \(count)ch", uid: "BlackHole\(count)ch_UID",
                                     inputChannels: Int(count), outputChannels: Int(count), isVirtual: true)
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count))
            let hardware = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true, channelLayout: layout)
            let plan = try DiagnosticFormatPolicy.plan(device: device, hardwareSource: hardware, hardwareSink: hardware,
                clientSource: inheritedSource, clientSink: inheritedSink)
            XCTAssertEqual(plan.source.channelCount, count); XCTAssertEqual(plan.sink.channelCount, count)
            XCTAssertEqual(plan.source.sampleRate, 48_000); XCTAssertEqual(plan.source.commonFormat, .pcmFormatFloat32)
            XCTAssertFalse(plan.source.isInterleaved); XCTAssertFalse(plan.sink.isInterleaved)
            try DiagnosticFormatPolicy.validateConfigured(device: device, plan: plan, hardwareSource: hardware,
                hardwareSink: hardware, clientSource: plan.source, clientSink: plan.sink)
            XCTAssertThrowsError(try DiagnosticFormatPolicy.validateConfigured(device: device, plan: plan, hardwareSource: hardware,
                hardwareSink: hardware, clientSource: inheritedSource, clientSink: inheritedSink))
        }
    }
    func testDiagnosticHardwareValidationRetainsFormatWidthAndRateGuardsAndDetails() throws {
        let device = AudioDevice(id: 11, name: "BlackHole 2ch", uid: "BlackHole2ch_UID", inputChannels: 2, outputChannels: 2, isVirtual: true)
        let good = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let invalid = [
            try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)),
            try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 4_000, channels: 2)),
            try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        ]
        for bad in invalid {
            XCTAssertThrowsError(try DiagnosticFormatPolicy.plan(device: device, hardwareSource: bad, hardwareSink: good,
                clientSource: good, clientSink: good))
            XCTAssertThrowsError(try DiagnosticFormatPolicy.plan(device: device, hardwareSource: good, hardwareSink: bad,
                clientSource: good, clientSink: good))
        }
        let details = DiagnosticFormatPolicy.failure(device: device, stage: "hardware format validation", hardwareSource: invalid[0],
            hardwareSink: good, clientSource: invalid[0], clientSink: good).localizedDescription
        for expected in ["BlackHole2ch_UID", "hardware source 1ch", "client source 1ch", "sink 2ch", "48000.0Hz", "Float32"] {
            XCTAssertTrue(details.contains(expected))
        }
    }
    func testDiagnosticConfiguredClientsMustKeepPlannedRateAndRepresentation() throws {
        let device = AudioDevice(id: 11, name: "BlackHole 2ch", uid: "BlackHole2ch_UID", inputChannels: 2, outputChannels: 2, isVirtual: true)
        let hardware = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let plan = try DiagnosticFormatPolicy.plan(device: device, hardwareSource: hardware, hardwareSink: hardware,
            clientSource: hardware, clientSink: hardware)
        let wrongRate = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let wrongType = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        for wrong in [wrongRate, wrongType] {
            XCTAssertThrowsError(try DiagnosticFormatPolicy.validateConfigured(device: device, plan: plan, hardwareSource: hardware,
                hardwareSink: hardware, clientSource: wrong, clientSink: plan.sink))
            XCTAssertThrowsError(try DiagnosticFormatPolicy.validateConfigured(device: device, plan: plan, hardwareSource: hardware,
                hardwareSink: hardware, clientSource: plan.source, clientSink: wrong))
        }
    }
    func testSpeechClientPreservesFirstPairAndSilencesAdditionalChannels() throws {
        let data = Data([0, 32, 0, 224, 0, 64])
        let expected = try PCM16.floats(data)
        for count: UInt32 in [1, 2, 16] {
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count))
            let hardware = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
            let format = try AudioClientFormat.make(hardware: hardware, sampleRate: 24_000)
            let buffer = try SpeechPlaybackBuffer.make(data: data, format: format)
            XCTAssertEqual(format.channelCount, count); XCTAssertEqual(format.sampleRate, 24_000)
            XCTAssertEqual(buffer.frameLength, 3)
            for channel in 0..<Int(count) {
                for frame in 0..<3 { XCTAssertEqual(buffer.floatChannelData![channel][frame], channel < 2 ? expected[frame] : 0) }
            }
            XCTAssertThrowsError(try SpeechPlaybackBuffer.make(data: Data(), format: format))
            XCTAssertThrowsError(try SpeechPlaybackBuffer.make(data: Data([1]), format: format))
        }
    }
    func testRouteNotificationRevalidationAcceptsUnchangedStateAndRejectsStoppedEnginesAndDrift() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let changed = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        func snapshot(inputRunning: Bool = true, outputRunning: Bool = true, outputClient: AVAudioFormat? = nil) -> AudioRouteIntegrity.Engines {
            AudioRouteIntegrity.Engines(inputHardware: stereo, inputClient: stereo, outputHardware: stereo,
                outputClient: outputClient ?? stereo, inputRunning: inputRunning, outputRunning: outputRunning)
        }
        let expected = snapshot()
        // A queued startup or unrelated inventory event is harmless only while all values
        // still match and both selected engines actually run.
        try snapshot().validate(expected: expected, requireRunning: true, context: "unchanged notification")
        XCTAssertThrowsError(try snapshot(inputRunning: false).validate(expected: expected, requireRunning: true, context: "input notification"))
        XCTAssertThrowsError(try snapshot(outputRunning: false).validate(expected: expected, requireRunning: true, context: "output notification"))
        XCTAssertThrowsError(try snapshot(outputClient: changed).validate(expected: expected, requireRunning: true, context: "format notification"))
        try snapshot(inputRunning: false, outputRunning: false).validate(expected: expected, requireRunning: false, context: "before startup")
    }
    func testRoutePropertySnapshotsPreserveDataSourceRateAndSemanticStreamTopology() throws {
        for unchanged in [AudioRoutePropertyValue.unsigned(1), .rate(48_000), .channels([2, 2]), .missing] {
            try AudioRouteIntegrity.equal(unchanged, unchanged, property: "selected property", context: "unchanged event")
        }
        let changes: [(AudioRoutePropertyValue, AudioRoutePropertyValue)] = [(.unsigned(1), .unsigned(0)), (.unsigned(10), .unsigned(11)),
            (.rate(48_000), .rate(44_100)), (.channels([2, 2]), .channels([4])), (.missing, .unsigned(10)), (.unsigned(10), .missing)]
        for (before, after) in changes {
            XCTAssertThrowsError(try AudioRouteIntegrity.equal(before, after, property: "selected property", context: "changed event"))
        }
        let bytes = MemoryLayout<AudioBufferList>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        list.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 16, mDataByteSize: 0, mData: nil)))
        let before = try AudioRouteWatch.topology(list, byteCount: bytes)
        list.pointee.mBuffers.mData = memory // Pointer and byte-size changes do not change channel topology.
        list.pointee.mBuffers.mDataByteSize = 4096
        XCTAssertEqual(try AudioRouteWatch.topology(list, byteCount: bytes), before)
        list.pointee.mNumberBuffers = 100
        XCTAssertThrowsError(try AudioRouteWatch.topology(list, byteCount: bytes))
    }
    func testRouteNotificationsCannotActDuringFailedSetupAfterStopOrOnLaterSessions() {
        var lifetime = AudioRouteNotificationLifetime()
        let first = lifetime.begin()
        XCTAssertFalse(lifetime.accepts(first)) // Setup has not completed.
        lifetime.activate(first); XCTAssertTrue(lifetime.accepts(first))
        lifetime.stop(); XCTAssertFalse(lifetime.accepts(first))
        let second = lifetime.begin(); lifetime.activate(first)
        XCTAssertFalse(lifetime.accepts(first)); XCTAssertFalse(lifetime.accepts(second))
        lifetime.activate(second); XCTAssertTrue(lifetime.accepts(second)); XCTAssertFalse(lifetime.accepts(first))
        let failedSetup = lifetime.begin(); lifetime.stop(); lifetime.activate(failedSetup)
        XCTAssertFalse(lifetime.accepts(failedSetup))
    }
    func testDiagnosticNoPromptAuthorizationPolicyOnlyAcceptsExistingGrant() {
        XCTAssertEqual(DiagnosticAuthorizationDecision.evaluate(.authorized, allowPermissionRequest: false), .approved)
        XCTAssertEqual(DiagnosticAuthorizationDecision.evaluate(.authorized, allowPermissionRequest: true), .approved)
        for status: AVAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            XCTAssertEqual(DiagnosticAuthorizationDecision.evaluate(status, allowPermissionRequest: false), .rejected)
        }
        XCTAssertEqual(DiagnosticAuthorizationDecision.evaluate(.notDetermined, allowPermissionRequest: true), .request)
        XCTAssertEqual(DiagnosticAuthorizationDecision.evaluate(.denied, allowPermissionRequest: true), .rejected)
    }
    @MainActor func testProductionTapCallbacksCreatedOnMainActorRunOnBackgroundExecutor() async throws {
        for (count, firstPair) in [(2, false), (2, true), (16, true)] {
            let source: AVAudioFormat
            if count == 2 { source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)) }
            else {
                let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(count)))
                source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
            }
            let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
            let converter = try XCTUnwrap(AVAudioConverter(from: firstPair ? mono : source, to: target)); converter.downmix = true
            let queue = PCMQueue()
            // Create the SAME factory used by both production installTap calls while on MainActor.
            let callback = AudioCallbackBridge.capture(CaptureConverter(converter: converter, target: target, queue: queue, firstPairInput: firstPair))
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    let legacyTap: AVAudioNodeTapBlock = callback
                    // Buffers stay entirely on this executor, like AVFoundation's borrowed tap buffer.
                    let format: AVAudioFormat
                    if count == 2 { format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)! }
                    else {
                        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(count))!
                        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
                    }
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
                    buffer.frameLength = 4800
                    for channel in 0..<count {
                        buffer.floatChannelData![channel].initialize(repeating: channel == 0 ? 0.1 : (channel == 1 ? 0.4 : 0.9), count: 4800)
                    }
                    for chunk in 0..<8 { legacyTap(buffer, AVAudioTime(sampleTime: Int64(chunk * 4800), atRate: 48_000)) }
                    continuation.resume()
                }
            }
            let samples = try PCM16.floats(queue.drain().reduce(Data(), +))
            XCTAssertTrue(abs(samples.count - 19_200) <= 512)
            XCTAssertEqual(samples[samples.count / 2], 0.25, accuracy: 0.01)
        }
    }
    @MainActor func testProductionCaptureProcessorSerializesConcurrentCallbacksAndClosedQueue() async throws {
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target)); converter.downmix = true
        let queue = PCMQueue()
        let callback = AudioCallbackBridge.capture(CaptureConverter(converter: converter, target: target, queue: queue))
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: 20) { chunk in
                    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
                    buffer.frameLength = 4800
                    for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.25, count: 4800) }
                    callback(buffer, AVAudioTime(sampleTime: Int64(chunk * 4800), atRate: 48_000))
                }
                continuation.resume()
            }
        }
        let samples = try PCM16.floats(queue.drain().reduce(Data(), +))
        XCTAssertTrue(abs(samples.count - 48_000) <= 512)
        XCTAssertEqual(samples[samples.count / 2], 0.25, accuracy: 0.01)
        queue.close()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
                buffer.frameLength = 4800
                for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.25, count: 4800) }
                callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
                continuation.resume()
            }
        }
        XCTAssertEqual(try queue.drain(), [])
    }
    @MainActor func testProductionPlaybackCompletionFactoryHopsToMainActor() async throws {
        let probe = PlaybackCompletionProbe()
        try probe.progress.schedule(2400)
        let generation = probe.generation
        await withCheckedContinuation { continuation in
            let callback = AudioCallbackBridge.playback {
                MainActor.preconditionIsolated()
                if probe.generation == generation { probe.progress.complete(2400) }
                continuation.resume()
            }
            DispatchQueue.global().async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                let legacyCompletion: AVAudioPlayerNodeCompletionHandler = callback
                legacyCompletion(.dataPlayedBack)
            }
        }
        XCTAssertEqual(probe.progress.playedFrames, 2400)
        probe.generation = UUID(); probe.progress.reset(); try probe.progress.schedule(4800)
        await withCheckedContinuation { continuation in
            let callback = AudioCallbackBridge.playback {
                MainActor.preconditionIsolated()
                if probe.generation == generation { probe.progress.complete(2400) }
                continuation.resume()
            }
            DispatchQueue.global().async { callback(.dataPlayedBack) }
        }
        XCTAssertEqual(probe.progress.playedFrames, 0); XCTAssertEqual(probe.progress.queuedFrames, 4800)
    }
    @MainActor func testExternalBindingResolvesEveryHalfBeforeBindingSharedUnits() throws {
        let plan = AudioEngineBindingPlan.make(mode: .externalBridge, inputID: 92, outputID: 61)
        let probe = LazyBindingProbe()
        try AudioEngineBindingPlan.configure(plan, resolve: probe.resolve, bind: probe.bind)
        XCTAssertEqual(probe.resolved, Set(AudioEngineEndpoint.allCases))
        XCTAssertEqual(probe.inputDeviceID, 92); XCTAssertEqual(probe.outputDeviceID, 61)
        XCTAssertEqual(probe.resolveCountAtFirstBinding, 4)
        try AudioEngineBindingPlan.validate(plan, observed: probe.observed, context: "after eager binding")
        // Demonstrate the modelled, observed failure mechanism: a later first lookup of
        // unused input resets the already-bound output half of its shared unit.
        let old = LazyBindingProbe()
        _ = old.resolve(.outputEngineOutput); old.bind(.outputEngineOutput, 61)
        _ = old.resolve(.outputEngineInput)
        XCTAssertEqual(old.outputDeviceID, 174)
    }
    func testExternalBindingChecksUnusedHalvesWhileRehearsalRemainsDirectional() throws {
        let external = AudioEngineBindingPlan.make(mode: .externalBridge, inputID: 92, outputID: 61)
        var observed: [AudioEngineEndpoint: UInt32] = [.inputEngineInput: 92, .inputEngineOutput: 92,
                                                    .outputEngineInput: 61, .outputEngineOutput: 61]
        try AudioEngineBindingPlan.validate(external, observed: observed, context: "stable virtual route")
        observed[.outputEngineInput] = 174
        XCTAssertThrowsError(try AudioEngineBindingPlan.validate(external, observed: observed, context: "unused input drift"))
        observed[.outputEngineInput] = nil
        XCTAssertThrowsError(try AudioEngineBindingPlan.validate(external, observed: observed, context: "missing unused input"))
        observed[.outputEngineInput] = 61; observed[.inputEngineOutput] = 119
        XCTAssertThrowsError(try AudioEngineBindingPlan.validate(external, observed: observed, context: "unused output drift"))
        let rehearsal = AudioEngineBindingPlan.make(mode: .rehearsal, inputID: 126, outputID: 119)
        XCTAssertEqual(rehearsal.map(\.endpoint), [.inputEngineInput, .outputEngineOutput])
        // Input-only microphone and output-only speakers need no unused-side binding.
        try AudioEngineBindingPlan.validate(rehearsal, observed: [.inputEngineInput: 126, .outputEngineOutput: 119], context: "directional rehearsal")
    }
    func testNativeExternalFormatRequires48kAndPreservesExactClientWidth() throws {
        for channels in [UInt32(2), 16] {
            let client = HALStreamFormat.floatClient(channels: channels)
            try HALStreamFormat.validateNative(client, role: "synthetic input")
            XCTAssertEqual(client.mSampleRate, 48_000)
            XCTAssertEqual(client.mChannelsPerFrame, channels)
            XCTAssertEqual(client.mBytesPerFrame, 4)
            XCTAssertTrue(client.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        }
        var invalid = HALStreamFormat.floatClient(channels: 2); invalid.mSampleRate = 44_100
        XCTAssertThrowsError(try HALStreamFormat.validateNative(invalid, role: "synthetic input"))
        invalid = HALStreamFormat.floatClient(channels: 1)
        XCTAssertThrowsError(try HALStreamFormat.validateNative(invalid, role: "synthetic input"))
        invalid = HALStreamFormat.floatClient(channels: 16); invalid.mFormatID = kAudioFormatMPEG4AAC
        XCTAssertThrowsError(try HALStreamFormat.validateNative(invalid, role: "synthetic output"))
        XCTAssertTrue(NativeExternalAudio.callbackFailure(-70003).contains("timestamp"))
    }
    @MainActor func testNativePresentationBoundsAndConstructionAreInert() throws {
        let bounds = try HALPresentation.validated(buffer: 128, safety: 32, deviceLatency: 64, streamLatency: 16, unitLatency: 0.001)
        XCTAssertEqual(bounds.frames, 416)
        XCTAssertThrowsError(try HALPresentation.validated(buffer: 0, safety: 0, deviceLatency: 0, streamLatency: 0, unitLatency: 0))
        XCTAssertThrowsError(try HALPresentation.validated(buffer: 128, safety: 8193, deviceLatency: 0, streamLatency: 0, unitLatency: 0))
        XCTAssertThrowsError(try HALPresentation.validated(buffer: 128, safety: 0, deviceLatency: 0, streamLatency: 0, unitLatency: .nan))
        let native = NativeExternalAudio()
        XCTAssertNil(native.stop()); XCTAssertNil(native.stop())
        XCTAssertEqual(try native.capture.drain(), [])
        XCTAssertThrowsError(try native.start(configuration(), routeChanged: { _ in }))
        let selected = SelectedDeviceAudio(); selected.stop()
        XCTAssertThrowsError(try selected.start(configuration(), routeChanged: { _ in }))
    }
    func testSimultaneousHALToneClassifierRejectsLeakageNoiseDropoutAndWrongFrequency() {
        let own = (0..<24_000).map { Float(LoopbackClassifier.amplitude * sin(2 * .pi * 730 * Double($0) / 24_000 + 0.4)) }
        let foreign = (0..<24_000).map { Float(LoopbackClassifier.amplitude * sin(2 * .pi * 997 * Double($0) / 24_000 + 0.2)) }
        XCTAssertTrue(HALToneClassifier.measure(own, frequency: 730, foreignFrequency: 997).passed)
        XCTAssertTrue(HALToneClassifier.measure(foreign, frequency: 997, foreignFrequency: 730).passed)
        let leaked = zip(own, foreign).map { $0 + 0.04 * $1 }
        XCTAssertFalse(HALToneClassifier.measure(leaked, frequency: 730, foreignFrequency: 997).passed)
        XCTAssertFalse(HALToneClassifier.measure(foreign, frequency: 730, foreignFrequency: 997).passed)
        var dropped = own; dropped.replaceSubrange(5000..<9000, with: repeatElement(Float(0), count: 4000))
        XCTAssertFalse(HALToneClassifier.measure(dropped, frequency: 730, foreignFrequency: 997).passed)
        let noise = own.enumerated().map { $0.element + Float(($0.offset % 7) - 3) * 0.004 }
        XCTAssertFalse(HALToneClassifier.measure(noise, frequency: 730, foreignFrequency: 997).passed)
        XCTAssertFalse(HALToneClassifier.measure(Array(own.prefix(12_000)), frequency: 730, foreignFrequency: 997).passed)
    }
    @MainActor func testCoordinatorBuffersTwelveSecondBurstWithHalfSecondHardwareLead() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("r"))
        var expected = Data()
        for byte in UInt8(1)...4 {
            let chunk = Data(repeating: byte, count: 144_000); expected.append(chunk)
            try bridge.processEvent(flowDelta(chunk, response: "r"))
        }
        XCTAssertEqual(bridge.state, .speaking); XCTAssertNil(bridge.lastError)
        XCTAssertTrue(bridge.flowDiagnostics().stagedOutputFrames > 240_000)
        try bridge.processEvent(flowDone("r"))
        for _ in 0..<30 { audio.completeAll(); try bridge.pumpOnce() }
        audio.completeAll(); try bridge.pumpOnce()
        XCTAssertEqual(audio.scheduledPCM, expected); XCTAssertEqual(bridge.state, .listening)
        XCTAssertTrue(audio.peakQueuedFrames <= 12_000); XCTAssertTrue(audio.scheduleSizes.allSatisfy { $0 <= 1_920 })
        bridge.stop(); await flowYield()
    }
    @MainActor func testCoordinatorConsolidatesTinyOutputFragmentsAndFlushesExactTail() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false); try bridge.processEvent(flowCreated("r"))
        var expected = Data()
        for i in 0..<2_000 {
            let chunk = Data([UInt8(i % 251), UInt8((i + 1) % 251)]); expected.append(chunk)
            try bridge.processEvent(flowDelta(chunk, response: "r"))
        }
        XCTAssertEqual(audio.scheduleSizes, [1_920, 1_920])
        try bridge.processEvent(flowDone("r")); XCTAssertEqual(audio.scheduleSizes, [1_920, 1_920, 160])
        audio.completeAll(); try bridge.pumpOnce(); XCTAssertEqual(audio.scheduledPCM, expected)
        bridge.stop(); await flowYield()
    }
    @MainActor func testCoordinatorSixtySecondBoundCancelsOnlyResponseAndKeepsListening() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false); try bridge.processEvent(flowCreated("r"))
        let chunk = Data(repeating: 1, count: 144_000)
        for _ in 0..<20 { try bridge.processEvent(flowDelta(chunk, response: "r")) }
        XCTAssertEqual(bridge.flowDiagnostics().stagedOutputFrames + audio.queuedPlaybackFrames, 1_440_000)
        try bridge.processEvent(flowDelta(chunk, response: "r")); await flowYield()
        XCTAssertEqual(bridge.state, .listening); XCTAssertFalse(audio.stopped)
        XCTAssertTrue(bridge.lastError?.contains("60-second") == true)
        XCTAssertEqual(bridge.flowDiagnostics().stagedOutputFrames, 0); XCTAssertEqual(audio.queuedPlaybackFrames, 0)
        let events = try sender.events(); XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["response.cancel", "conversation.item.truncate"])
        XCTAssertEqual(events.last?["audio_end_ms"] as? Int, 0)
        try bridge.processEvent(flowDelta(chunk, response: "r")); XCTAssertEqual(audio.queuedPlaybackFrames, 0)
        bridge.stop(); await flowYield()
    }
    @MainActor func testCoordinatorBargeInAfterResponseDoneDropsStagingAndRejectsLateChunks() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false); try bridge.processEvent(flowCreated("r"))
        try bridge.processEvent(flowDelta(Data(repeating: 1, count: 144_000), response: "r")); try bridge.processEvent(flowDone("r"))
        audio.complete(frames: 960)
        try bridge.processEvent(["type": "input_audio_buffer.speech_started"]); await flowYield()
        XCTAssertEqual(bridge.state, .listening); XCTAssertEqual(audio.queuedPlaybackFrames, 0)
        XCTAssertEqual(bridge.flowDiagnostics().stagedOutputFrames, 0)
        let events = try sender.events(); XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "conversation.item.truncate")
        XCTAssertEqual(events.first?["audio_end_ms"] as? Int, 40)
        let bytes = audio.scheduledPCM.count
        try bridge.processEvent(flowDelta(Data(repeating: 2, count: 1_920), response: "r"))
        try bridge.processEvent(flowCreated("r")); try bridge.pumpOnce(); XCTAssertEqual(audio.scheduledPCM.count, bytes)
        bridge.stop(); await flowYield()
    }
    @MainActor func testCoordinatorTinyStagedItemTruncatesZeroInsteadOfPriorPlayback() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        audio.item = "prior-item"; audio.confirmedFrames = 9_600
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false); try bridge.processEvent(flowCreated("r"))
        try bridge.processEvent(flowDelta(Data([1,2]), response: "r")); XCTAssertTrue(audio.scheduleSizes.isEmpty)
        try bridge.processEvent(flowDone("r")); // done flushes the tail; repeat with an unscheduled fresh item.
        audio.completeAll(); try bridge.pumpOnce()
        try bridge.processEvent(flowCreated("tiny")); try bridge.processEvent(flowDelta(Data([3,4]), response: "tiny", item: "tiny-item"))
        try bridge.processEvent(["type": "input_audio_buffer.speech_started"]); await flowYield()
        let events = try sender.events(); XCTAssertEqual(events.last?["item_id"] as? String, "tiny-item")
        XCTAssertEqual(events.last?["audio_end_ms"] as? Int, 0)
        XCTAssertEqual(bridge.flowDiagnostics().stagedOutputFrames, 0)
        bridge.stop(); await flowYield()
    }
    @MainActor func testCoordinatorBatchesInputPreservesTailAndPrioritizesControls() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator(); sender.blocked = true
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        let first = Data((0..<1_920).map { UInt8($0 % 251) }), second = Data((0..<2_020).map { UInt8(($0 + 7) % 251) })
        audio.capture.push(first.prefix(480)); try bridge.pumpOnce(); await flowYield(); XCTAssertTrue(sender.messages.isEmpty)
        audio.capture.push(first.dropFirst(480)); try bridge.pumpOnce(); await flowYield(); XCTAssertEqual(sender.messages.count, 1)
        audio.capture.push(second.prefix(1_010)); audio.capture.push(second.dropFirst(1_010)); try bridge.pumpOnce()
        try bridge.processEvent(flowCreated("r")); try bridge.processEvent(flowDelta(Data([1,2]), response: "r"))
        try bridge.processEvent(["type": "input_audio_buffer.speech_started"])
        sender.release(); await flowYield(); try bridge.pumpOnce(); await flowYield()
        let events = try sender.events(), types = events.compactMap { $0["type"] as? String }
        XCTAssertEqual(Array(types.prefix(3)), ["input_audio_buffer.append", "response.cancel", "conversation.item.truncate"])
        var captured = Data()
        for event in events where event["type"] as? String == "input_audio_buffer.append" {
            captured.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(event["audio"] as? String))))
        }
        XCTAssertEqual(captured, first + second); XCTAssertTrue(events.filter { $0["type"] as? String == "input_audio_buffer.append" }.count <= 3)
        bridge.stop(); await flowYield()
    }
    @MainActor func testOutgoingHardBoundIncludesBlockedControlAndInputFlights() async throws {
        var queue = VoiceOutgoingBuffer(); try queue.appendPCM(Data(repeating: 1, count: 100_000))
        queue.flushInputTail(); _ = try XCTUnwrap(queue.next()); XCTAssertTrue(queue.inFlightBytes > 0)
        try queue.appendControl(String(repeating: "c", count: 8_000)); try queue.appendControl(String(repeating: "t", count: 8_000))
        XCTAssertTrue(queue.reservedBytes <= 160_000); XCTAssertTrue(queue.reservedMessages <= 128)
        queue.sent(); XCTAssertEqual(try queue.next(), String(repeating: "c", count: 8_000))
        XCTAssertThrowsError(try queue.appendControl("x")) // in-flight8KB + pending8KB fills control lane.
        XCTAssertTrue(queue.reservedBytes <= 160_000)
        queue.sent(); XCTAssertEqual(try queue.next(), String(repeating: "t", count: 8_000)); queue.sent()
        XCTAssertTrue(try XCTUnwrap(queue.next()).contains("input_audio_buffer.append"))
        queue.clear(); XCTAssertEqual(queue.reservedBytes, 0)
        let setup = String(repeating: "s", count: 150_000)
        try queue.appendSetup(setup); XCTAssertEqual(try queue.next(), setup)
        XCTAssertEqual(queue.reservedBytes, 150_000) // Setup stays charged until local send completion, even after acknowledgement.
        XCTAssertThrowsError(try queue.appendPCM(Data([1,2])))
        queue.clear(); try queue.appendPCM(Data(repeating: 255, count: 100_000))
        let before = queue.reservedBytes, slashRich = try XCTUnwrap(queue.next())
        XCTAssertFalse(slashRich.contains("\\/")); XCTAssertTrue(queue.reservedBytes <= before)
        let decoded = try RealtimeProtocol.parse(slashRich)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(decoded["audio"] as? String)), Data(repeating: 255, count: 1_920))
        queue.clear()
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator(); sender.blocked = true
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        for _ in 0..<100 { audio.capture.push(Data(repeating: 1, count: 960)); try bridge.pumpOnce(); await flowYield() }
        XCTAssertTrue(bridge.flowDiagnostics().outgoingReservedBytes <= 144_000)
        try bridge.processEvent(flowCreated("r")); try bridge.processEvent(flowDelta(Data([1,2]), response: "r"))
        try bridge.processEvent(["type": "input_audio_buffer.speech_started"])
        XCTAssertTrue(bridge.flowDiagnostics().outgoingReservedBytes <= 160_000)
        bridge.stop(); sender.release(); await flowYield()
    }
    @MainActor func testCoordinatorCaptureAndOutgoingOverflowsHaveDistinctNumericEvidence() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator(); sender.blocked = true
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        var message: String?
        for _ in 0..<160 {
            audio.capture.push(Data(repeating: 1, count: 960))
            do { try bridge.pumpOnce() } catch { message = error.localizedDescription; break }
            await flowYield()
        }
        XCTAssertTrue(message?.contains("Outgoing capture") == true); XCTAssertTrue(message?.contains("inFlight=") == true)
        bridge.stop(); sender.release(); await flowYield()
        let capture = FlowAudioProbe(), fresh = VoiceBridgeCoordinator(), freshSender = FlowSenderProbe()
        fresh.attachConfiguredAudio(capture, send: freshSender.send, runPump: false)
        capture.capture.push(Data(repeating: 0, count: 96_000)); capture.capture.push(Data([0,0]))
        do { try fresh.pumpOnce(); preconditionFailure("Expected capture overflow") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Capture PCM")); XCTAssertTrue(error.localizedDescription.contains("incoming=2bytes")) }
        fresh.stop(); await flowYield()
    }
    @MainActor func testCoordinatorBargeInCancelsNewActiveResponseBeforeItsFirstDelta() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("old")); try bridge.processEvent(flowDelta(Data(repeating: 1, count: 1_920), response: "old"))
        try bridge.processEvent(flowDone("old")); audio.completeAll() // Old staging identity remains until the next pump.
        try bridge.processEvent(flowCreated("new")); try bridge.processEvent(["type": "input_audio_buffer.speech_started"]); await flowYield()
        let events = try sender.events(); XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "response.cancel"); XCTAssertEqual(events.first?["response_id"] as? String, "new")
        let oldBytes = audio.scheduledPCM.count
        try bridge.processEvent(flowDelta(Data(repeating: 2, count: 1_920), response: "new")); XCTAssertEqual(audio.scheduledPCM.count, oldBytes)
        bridge.stop(); await flowYield()
        let fresh = FlowAudioProbe(), freshSender = FlowSenderProbe()
        bridge.attachConfiguredAudio(fresh, send: freshSender.send, runPump: false)
        try bridge.processEvent(flowCreated("cold")); try bridge.processEvent(["type": "input_audio_buffer.speech_started"]); await flowYield()
        XCTAssertEqual(try freshSender.events().first?["response_id"] as? String, "cold")
        try bridge.processEvent(flowDelta(Data([1,2]), response: "cold")); XCTAssertTrue(fresh.scheduledPCM.isEmpty)
        bridge.stop(); await flowYield()
    }
    @MainActor func testMicrophoneAuthorizationRequestsOnlyWhenUndetermined() async throws {
        var requests = 0
        let allowed = try await MicrophoneAuthorization.authorize(status: .authorized) { requests += 1; return false }
        XCTAssertTrue(allowed); XCTAssertEqual(requests, 0)
        for status in [AVAuthorizationStatus.denied, .restricted] {
            let denied = try await MicrophoneAuthorization.authorize(status: status) { requests += 1; return true }
            XCTAssertFalse(denied)
        }
        XCTAssertEqual(requests, 0)
        let newlyAllowed = try await MicrophoneAuthorization.authorize(status: .notDetermined) { requests += 1; return true }
        XCTAssertTrue(newlyAllowed); XCTAssertEqual(requests, 1)
        let newlyDenied = try await MicrophoneAuthorization.authorize(status: .notDetermined) { requests += 1; return false }
        XCTAssertFalse(newlyDenied); XCTAssertEqual(requests, 2)
    }
    @MainActor func testMicrophonePermissionCancellationCannotProceed() async throws {
        var reply: CheckedContinuation<Bool, Never>?
        let task = Task { @MainActor in
            try await MicrophoneAuthorization.authorize(status: .notDetermined) {
                await withCheckedContinuation { reply = $0 }
            }
        }
        await flowYield()
        let callback = try XCTUnwrap(reply)
        task.cancel(); callback.resume(returning: true)
        do { _ = try await task.value; preconditionFailure("Canceled permission request must not proceed") }
        catch is CancellationError {} catch { throw error }
    }
    func testFinishFunctionValidatesCompletedEmptyArgumentsAndFixedFarewell() throws {
        let response = try XCTUnwrap(flowFinish("r")["response"] as? [String: Any])
        XCTAssertEqual(try RealtimeProtocol.finishCallID(response), "finish-call")
        var canceled = response; canceled["status"] = "cancelled"
        XCTAssertNil(try RealtimeProtocol.finishCallID(canceled))
        var invalid = response
        invalid["output"] = [["type": "function_call", "name": "finish_conversation", "status": "completed", "call_id": "finish-call", "arguments": "{\"phone\":true}"]]
        XCTAssertThrowsError(try RealtimeProtocol.finishCallID(invalid))
        let farewell = try RealtimeProtocol.parse(RealtimeProtocol.farewellResponse(token: "test-token"))
        let body = try XCTUnwrap(farewell["response"] as? [String: Any])
        XCTAssertEqual(body["tool_choice"] as? String, "none")
        XCTAssertEqual((body["metadata"] as? [String: String])?["solar_farewell"], "test-token")
        XCTAssertTrue((body["instructions"] as? String)?.contains("Thank you. Goodbye.") == true)
    }
    @MainActor func testConversationFinishWaitsForFarewellPlaybackAndStopsOnce() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator(conversationFinishDelay: .zero)
        var finished = 0
        bridge.onEvent = { if case .conversationCompleted = $0 { finished += 1 } }
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("finish")); try bridge.processEvent(flowFinish("finish")); await flowYield()
        let events = try sender.events()
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["conversation.item.create", "response.create"])
        let request = try XCTUnwrap(events.last?["response"] as? [String: Any])
        let metadata = try XCTUnwrap(request["metadata"] as? [String: String])
        try bridge.processEvent(["type": "response.created", "response": ["id": "bye", "metadata": metadata]])
        try bridge.processEvent(flowDelta(Data([1, 2]), response: "bye", item: "bye-item"))
        try bridge.processEvent(flowDone("bye"))
        XCTAssertFalse(audio.stopped); XCTAssertEqual(finished, 0); XCTAssertEqual(audio.queuedPlaybackFrames, 1)
        audio.completeAll(); try bridge.pumpOnce(); await flowYield()
        XCTAssertTrue(audio.stopped); XCTAssertEqual(bridge.state, .idle); XCTAssertEqual(finished, 1)
        try bridge.processEvent(flowDone("bye")); try bridge.pumpOnce(); XCTAssertEqual(finished, 1)
    }
    @MainActor func testNewSpeechCancelsPendingFarewellAndRejectsItsLateResponse() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("finish")); try bridge.processEvent(flowFinish("finish")); await flowYield()
        let request = try XCTUnwrap(sender.events().last?["response"] as? [String: Any])
        let metadata = try XCTUnwrap(request["metadata"] as? [String: String])
        try bridge.processEvent(["type": "input_audio_buffer.speech_started"])
        try bridge.processEvent(["type": "response.created", "response": ["id": "late-bye", "metadata": metadata]])
        try bridge.processEvent(flowDelta(Data([9, 9]), response: "late-bye"))
        try bridge.processEvent(flowDone("late-bye")); await flowYield()
        XCTAssertTrue(audio.scheduledPCM.isEmpty); XCTAssertFalse(audio.stopped)
        XCTAssertTrue(try sender.events().contains { $0["type"] as? String == "response.cancel" && $0["response_id"] as? String == "late-bye" })
        try bridge.processEvent(["type": "input_audio_buffer.speech_stopped"])
        try bridge.processEvent(flowCreated("continue"))
        try bridge.processEvent(flowDelta(Data([3, 4]), response: "continue")); try bridge.processEvent(flowDone("continue"))
        audio.completeAll(); try bridge.pumpOnce(); await flowYield()
        XCTAssertEqual(audio.scheduledPCM, Data([3, 4])); XCTAssertEqual(bridge.state, .listening)
        bridge.stop()
    }
    @MainActor func testNewSpeechDuringClosingGraceKeepsConversationOpen() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator(conversationFinishDelay: .seconds(30))
        var finished = 0
        bridge.onEvent = { if case .conversationCompleted = $0 { finished += 1 } }
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("finish")); try bridge.processEvent(flowFinish("finish")); await flowYield()
        let request = try XCTUnwrap(sender.events().last?["response"] as? [String: Any])
        let metadata = try XCTUnwrap(request["metadata"] as? [String: String])
        try bridge.processEvent(["type": "response.created", "response": ["id": "bye", "metadata": metadata]])
        try bridge.processEvent(flowDelta(Data([1, 2]), response: "bye")); try bridge.processEvent(flowDone("bye"))
        audio.completeAll(); try bridge.pumpOnce()
        try bridge.processEvent(["type": "input_audio_buffer.speech_started"])
        audio.capture.push(Data(repeating: 5, count: 1_920)); try bridge.pumpOnce(); await flowYield()
        XCTAssertTrue(try sender.events().contains { $0["type"] as? String == "input_audio_buffer.append" })
        XCTAssertFalse(audio.stopped); XCTAssertEqual(finished, 0)
        try bridge.processEvent(["type": "input_audio_buffer.speech_stopped"])
        try bridge.processEvent(flowCreated("more")); try bridge.processEvent(flowDone("more")); await flowYield()
        XCTAssertEqual(bridge.state, .listening); XCTAssertEqual(finished, 0)
        bridge.stop()
    }
    @MainActor func testInterruptedFinishWhileOldAudioPlaysResolvesToolWithoutClosing() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("finish"))
        try bridge.processEvent(flowDelta(Data(repeating: 1, count: 1_920), response: "finish"))
        try bridge.processEvent(flowFinish("finish")); await flowYield()
        XCTAssertTrue(sender.messages.isEmpty)
        try bridge.processEvent(["type": "input_audio_buffer.speech_started"]); await flowYield()
        let events = try sender.events()
        let result = try XCTUnwrap(events.first?["item"] as? [String: Any])
        XCTAssertEqual(result["call_id"] as? String, "finish-call")
        XCTAssertTrue((result["output"] as? String)?.contains("person_continued_speaking") == true)
        XCTAssertFalse(events.contains { $0["type"] as? String == "response.create" })
        XCTAssertFalse(audio.stopped); XCTAssertEqual(bridge.state, .listening)
        bridge.stop()
    }
    @MainActor func testConversationFinishWaitsForPriorAudioAndRejectsExtraResponses() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("finish"))
        try bridge.processEvent(flowDelta(Data(repeating: 1, count: 1_920), response: "finish"))
        try bridge.processEvent(flowFinish("finish")); await flowYield()
        XCTAssertTrue(sender.messages.isEmpty)
        try bridge.processEvent(flowCreated("extra")); await flowYield()
        XCTAssertEqual(try sender.events().first?["type"] as? String, "response.cancel")
        audio.completeAll(); try bridge.pumpOnce(); await flowYield()
        XCTAssertEqual(try sender.events().filter { $0["type"] as? String == "response.create" }.count, 1)
        let bytes = audio.scheduledPCM.count
        try bridge.processEvent(flowDelta(Data([9, 9]), response: "extra")); XCTAssertEqual(audio.scheduledPCM.count, bytes)
        try bridge.processEvent(flowFinish("finish")); await flowYield()
        XCTAssertEqual(try sender.events().filter { $0["type"] as? String == "response.create" }.count, 1)
        bridge.stop(); await flowYield()
    }
    @MainActor func testCanceledOrStaleFinishCannotCloseAnotherSession() async throws {
        let audio = FlowAudioProbe(), sender = FlowSenderProbe(), bridge = VoiceBridgeCoordinator()
        bridge.attachConfiguredAudio(audio, send: sender.send, runPump: false)
        try bridge.processEvent(flowCreated("old"))
        try bridge.processEvent(flowFinish("old", status: "cancelled")); await flowYield()
        XCTAssertTrue(sender.messages.isEmpty); XCTAssertFalse(audio.stopped)
        bridge.stop()
        let fresh = FlowAudioProbe(), freshSender = FlowSenderProbe()
        bridge.attachConfiguredAudio(fresh, send: freshSender.send, runPump: false)
        try bridge.processEvent(flowCreated("new")); try bridge.processEvent(flowFinish("old")); await flowYield()
        XCTAssertTrue(freshSender.messages.isEmpty); XCTAssertFalse(fresh.stopped)
        bridge.stop()
    }
    @MainActor func testCoordinatorStopAndNewSessionCannotReceiveOldSenderCompletionOrAudio() async throws {
        let old = FlowAudioProbe(), blocked = FlowSenderProbe(), bridge = VoiceBridgeCoordinator(); blocked.blocked = true
        bridge.attachConfiguredAudio(old, send: blocked.send, runPump: false)
        old.capture.push(Data(repeating: 1, count: 1_920)); try bridge.pumpOnce(); await flowYield()
        try bridge.processEvent(flowCreated("old")); try bridge.processEvent(flowDelta(Data(repeating: 3, count: 144_000), response: "old"))
        bridge.stop(); XCTAssertTrue(old.stopped); XCTAssertEqual(bridge.flowDiagnostics().outgoingReservedBytes, 0)
        let fresh = FlowAudioProbe(), sender = FlowSenderProbe()
        bridge.attachConfiguredAudio(fresh, send: sender.send, runPump: false)
        fresh.capture.push(Data(repeating: 4, count: 1_920)); try bridge.pumpOnce(); blocked.release(); await flowYield()
        XCTAssertEqual(sender.messages.count, 1); XCTAssertEqual(bridge.flowDiagnostics().outgoingReservedBytes, 0)
        try bridge.processEvent(flowDelta(Data(repeating: 9, count: 1_920), response: "old")); XCTAssertTrue(fresh.scheduledPCM.isEmpty)
        XCTAssertEqual(bridge.state, .listening); XCTAssertFalse(fresh.stopped)
        bridge.stop(); await flowYield()
    }
}

@MainActor private final class FlowAudioProbe: VoiceAudioEndpoint {
    let capture = PCMQueue()
    var onDrained: (() -> Void)?
    var queuedPlaybackFrames: Int64 = 0
    var peakQueuedFrames: Int64 = 0
    var confirmedFrames: Int64 = 0
    var item: String?
    var index = 0
    var stopped = false
    var scheduledPCM = Data()
    var scheduleSizes: [Int] = []
    func verifyDevices(stage: String, requireRunning: Bool?) throws { precondition(!stopped) }
    func play(_ data: Data, item: String, index: Int) throws {
        precondition(!stopped)
        if self.item != item || self.index != index { precondition(queuedPlaybackFrames == 0); confirmedFrames = 0; self.item = item; self.index = index }
        queuedPlaybackFrames += Int64(data.count / 2); peakQueuedFrames = max(peakQueuedFrames, queuedPlaybackFrames)
        precondition(queuedPlaybackFrames <= 240_000)
        scheduledPCM.append(data); scheduleSizes.append(data.count)
    }
    func complete(frames: Int64) { let amount = min(frames, queuedPlaybackFrames); queuedPlaybackFrames -= amount; confirmedFrames += amount; if queuedPlaybackFrames == 0 { onDrained?() } }
    func completeAll() { complete(frames: queuedPlaybackFrames) }
    func interrupt() -> (item: String, index: Int, frames: Int64)? {
        let result = item.map { (item: $0, index: index, frames: confirmedFrames) }
        queuedPlaybackFrames = 0; item = nil; confirmedFrames = 0; return result
    }
    func stop() -> String? { stopped = true; capture.close(); queuedPlaybackFrames = 0; onDrained = nil; return nil }
}
@MainActor private final class FlowSenderProbe {
    var messages: [String] = []
    var blocked = false
    private var continuation: CheckedContinuation<Void, Error>?
    func send(_ text: String) async throws {
        messages.append(text)
        if blocked { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func release() { blocked = false; let pending = continuation; continuation = nil; pending?.resume() }
    func events() throws -> [[String: Any]] { try messages.map(RealtimeProtocol.parse) }
}
@MainActor private func flowYield() async { for _ in 0..<20 { await Task.yield() } }
private func flowCreated(_ response: String) -> [String: Any] { ["type": "response.created", "response": ["id": response]] }
private func flowDone(_ response: String) -> [String: Any] { ["type": "response.done", "response": ["id": response, "status": "completed"]] }
private func flowFinish(_ response: String, status: String = "completed") -> [String: Any] {
    ["type": "response.done", "response": ["id": response, "status": status, "output": [[
        "type": "function_call", "status": "completed", "name": "finish_conversation", "call_id": "finish-call", "arguments": "{}"
    ]]]]
}
private func flowDelta(_ data: Data, response: String, item: String = "item") -> [String: Any] {
    ["type": "response.output_audio.delta", "response_id": response, "item_id": item, "content_index": 0, "delta": data.base64EncodedString()]
}

@MainActor private final class PlaybackCompletionProbe {
    var progress = PlaybackProgress()
    var generation = UUID()
}

@MainActor private final class LazyBindingProbe {
    var resolved = Set<AudioEngineEndpoint>()
    var inputDeviceID: UInt32 = 126
    var outputDeviceID: UInt32 = 119
    var resolveCountAtFirstBinding: Int?
    func resolve(_ endpoint: AudioEngineEndpoint) -> AudioEngineEndpoint {
        if resolved.insert(endpoint).inserted {
            switch endpoint {
            case .inputEngineOutput: inputDeviceID = 174
            case .outputEngineInput: outputDeviceID = 174
            default: break
            }
        }
        return endpoint
    }
    func bind(_ endpoint: AudioEngineEndpoint, _ id: UInt32) {
        if resolveCountAtFirstBinding == nil { resolveCountAtFirstBinding = resolved.count }
        switch endpoint {
        case .inputEngineInput, .inputEngineOutput: inputDeviceID = id
        case .outputEngineInput, .outputEngineOutput: outputDeviceID = id
        }
    }
    var observed: [AudioEngineEndpoint: UInt32] {
        [.inputEngineInput: inputDeviceID, .inputEngineOutput: inputDeviceID,
         .outputEngineInput: outputDeviceID, .outputEngineOutput: outputDeviceID]
    }
}

#if VOICE_SELF_CHECK
@main struct VoiceSelfCheck {
    @MainActor static func main() async throws {
        let tests = VoiceBridgeTests()
        try tests.testIndependentVirtualDevicesWithAcknowledgmentAccepted()
        try tests.testExternalRouteRejectsFeedbackMissingDevicesPhysicalAndNoAcknowledgment()
        tests.testHotplugReusedIDAndUnpinnedIDRejected()
        try tests.testRehearsalSupportsSelectedPhysicalMicAndHeadphones()
        try tests.testSessionJSONAndConfigurationAcknowledgment()
        tests.testEndpointCannotBeChangedByModel()
        try tests.testPCMEndianSignedRangeAndMalformedEvents()
        try tests.testAppendAndTruncateUsePCMAndPlayedFramesOnly()
        try tests.testQueueBoundsOrderOverflowAndStop()
        try tests.testMemoryOnlyStereo48kConversionToMonoPCM24k()
        tests.testIdleAndStopDoNotStartIO()
        try tests.testPlaybackUnderrunDoesNotCountUnheardAudioAndBudgetIsBounded()
        try tests.testStreamingConversionDoesNotRepeatChunks()
        try tests.test16ChannelCallerFirstPairWithSilentRemainingChannels()
        try tests.testDiagnosticRejectsMirrorsHardwareStaleIdentityAndMissingAcknowledgment()
        tests.testDiagnosticClassifierRequiresKnownSignalAmplitudeContinuityAndIsolation()
        tests.testDiagnosticConstructionAndStopAreInert()
        try tests.testDiagnosticPlansUseHardwareChannelsInsteadOfInheritedMonoAndStereoClients()
        try tests.testDiagnosticHardwareValidationRetainsFormatWidthAndRateGuardsAndDetails()
        try tests.testDiagnosticConfiguredClientsMustKeepPlannedRateAndRepresentation()
        try tests.testSpeechClientPreservesFirstPairAndSilencesAdditionalChannels()
        try tests.testRouteNotificationRevalidationAcceptsUnchangedStateAndRejectsStoppedEnginesAndDrift()
        try tests.testRoutePropertySnapshotsPreserveDataSourceRateAndSemanticStreamTopology()
        tests.testRouteNotificationsCannotActDuringFailedSetupAfterStopOrOnLaterSessions()
        tests.testDiagnosticNoPromptAuthorizationPolicyOnlyAcceptsExistingGrant()
        try await tests.testProductionTapCallbacksCreatedOnMainActorRunOnBackgroundExecutor()
        try await tests.testProductionCaptureProcessorSerializesConcurrentCallbacksAndClosedQueue()
        try await tests.testProductionPlaybackCompletionFactoryHopsToMainActor()
        try tests.testExternalBindingResolvesEveryHalfBeforeBindingSharedUnits()
        try tests.testExternalBindingChecksUnusedHalvesWhileRehearsalRemainsDirectional()
        try tests.testNativeExternalFormatRequires48kAndPreservesExactClientWidth()
        try tests.testNativePresentationBoundsAndConstructionAreInert()
        tests.testSimultaneousHALToneClassifierRejectsLeakageNoiseDropoutAndWrongFrequency()
        try await tests.testCoordinatorBuffersTwelveSecondBurstWithHalfSecondHardwareLead()
        try await tests.testCoordinatorConsolidatesTinyOutputFragmentsAndFlushesExactTail()
        try await tests.testCoordinatorSixtySecondBoundCancelsOnlyResponseAndKeepsListening()
        try await tests.testCoordinatorBargeInAfterResponseDoneDropsStagingAndRejectsLateChunks()
        try await tests.testCoordinatorTinyStagedItemTruncatesZeroInsteadOfPriorPlayback()
        try await tests.testCoordinatorBatchesInputPreservesTailAndPrioritizesControls()
        try await tests.testOutgoingHardBoundIncludesBlockedControlAndInputFlights()
        try await tests.testCoordinatorCaptureAndOutgoingOverflowsHaveDistinctNumericEvidence()
        try await tests.testCoordinatorBargeInCancelsNewActiveResponseBeforeItsFirstDelta()
        try await tests.testCoordinatorStopAndNewSessionCannotReceiveOldSenderCompletionOrAudio()
        try await tests.testMicrophoneAuthorizationRequestsOnlyWhenUndetermined()
        try await tests.testMicrophonePermissionCancellationCannotProceed()
        try tests.testFinishFunctionValidatesCompletedEmptyArgumentsAndFixedFarewell()
        try await tests.testConversationFinishWaitsForFarewellPlaybackAndStopsOnce()
        try await tests.testConversationFinishWaitsForPriorAudioAndRejectsExtraResponses()
        try await tests.testCanceledOrStaleFinishCannotCloseAnotherSession()
        try await tests.testNewSpeechCancelsPendingFarewellAndRejectsItsLateResponse()
        try await tests.testNewSpeechDuringClosingGraceKeepsConversationOpen()
        try await tests.testInterruptedFinishWhileOldAudioPlaysResolvesToolWithoutClosing()
        print("PASS: 52 VoiceBridge checks; synthetic buffers only, no hardware capture or API session.")
    }
}
#endif
