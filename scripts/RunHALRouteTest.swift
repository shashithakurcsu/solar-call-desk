// Explicitly reviewed local synthetic run only. No VoiceBridgeCoordinator, URLSession,
// API credentials, phone app, permission requests, physical routes or audio files.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

@MainActor private final class RunState {
    var error: String?
    var cleanupErrors: [String] = []
}

@main struct RunHALRouteTest {
    struct Snapshot: Equatable { let ids: [UInt32]; let defaults: [UInt32] }
    static func defaults() throws -> [UInt32] {
        try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
            .map { try AudioDeviceCatalog.scalar(UInt32(kAudioObjectSystemObject), $0) }
    }
    static func ids() throws -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try AudioDeviceCatalog.check(AudioObjectGetPropertyDataSize(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0, size <= 65_536, size.isMultiple(of: 4) else { throw VoiceBridgeError.route("Invalid device inventory; no I/O allowed.") }
        var result = [UInt32](repeating: 0, count: Int(size / 4))
        try result.withUnsafeMutableBytes { try AudioDeviceCatalog.check(AudioObjectGetPropertyData(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)) }
        return result.sorted()
    }
    static func idleSnapshot() throws -> Snapshot {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw VoiceBridgeError.configuration("Existing microphone authorization required; this runner never requests permission.")
        }
        let snapshot = Snapshot(ids: try ids(), defaults: try defaults())
        for id in snapshot.ids {
            guard try AudioDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 else {
                throw VoiceBridgeError.route("Device \(id) is already in use; no I/O allowed.")
            }
        }
        return snapshot
    }
    static func tone(frequency: Double, offset: Int, frames: Int = 4800) -> Data {
        var data = Data(capacity: frames * 2)
        for index in offset..<(offset + frames) {
            let ramp = min(1, Double(index) / 480)
            let sample = Int16((32768 * LoopbackClassifier.amplitude * ramp * sin(2 * .pi * frequency * Double(index) / 24_000)).rounded())
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 255)); data.append(UInt8(bits >> 8))
        }
        return data
    }
    static func metrics(_ value: HALToneMetrics) -> [String: Any] {
        ["ownRMS": value.ownRMS, "foreignToneRMS": value.foreignRMS, "correlation": value.correlation,
         "gain": value.gain, "leakageRatio": value.leakageRatio, "analyzedFrames": value.analyzedFrames, "passed": value.passed]
    }
    @MainActor static func main() async {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--run-reviewed-local-hal-test"] else {
            print("ABORT: explicit --run-reviewed-local-hal-test required; no I/O."); Foundation.exit(2)
        }
        let forward = SelectedDeviceAudio(), reverse = SelectedDeviceAudio(), state = RunState()
        var report: [String: Any] = ["scope": "28 seconds maximum local first-pair synthetic HAL test; Phone/API and channels 3–16 are unverified.",
            "permissionRequested": false, "networkUsed": false, "audioFilesWritten": false]
        var before: Snapshot?
        var liveStarted: ContinuousClock.Instant?
        var passed = false
        do {
            let initial = try idleSnapshot(); before = initial
            let devices = try AudioDeviceCatalog.devices()
            func select(_ uid: String, channels: Int) throws -> AudioDevice {
                let matches = devices.filter { $0.uid == uid }
                guard matches.count == 1, let device = matches.first, device.isVirtual,
                      device.inputChannels == channels, device.outputChannels == channels else {
                    throw VoiceBridgeError.route("Exact primary \(uid) \(channels)ch device required.")
                }
                return device
            }
            let two = try select("BlackHole2ch_UID", channels: 2), sixteen = try select("BlackHole16ch_UID", channels: 16)
            func configuration(input: AudioDevice, output: AudioDevice) -> VoiceBridgeConfiguration {
                VoiceBridgeConfiguration(inputDeviceID: input.id, outputDeviceID: output.id, mode: .externalBridge,
                    instructions: "Local synthetic test only.", externalRoutingAcknowledged: true,
                    inputDeviceUID: input.uid, outputDeviceUID: output.uid)
            }
            let normal = configuration(input: two, output: sixteen), peer = configuration(input: sixteen, output: two)
            try normal.validate(devices: devices); try peer.validate(devices: devices)
            guard try idleSnapshot() == initial else { throw VoiceBridgeError.route("Preflight changed; no I/O allowed.") }
            report["defaultsBefore"] = initial.defaults; report["deviceIDsBefore"] = initial.ids
            report["inputID"] = two.id; report["outputID"] = sixteen.id; report["nativeRate"] = 48_000
            report["preflightAllDevicesIdle"] = true
            let changed: @MainActor @Sendable (String) -> Void = { message in
                guard state.error == nil else { return }
                state.error = message
                state.cleanupErrors += [forward.stop(), reverse.stop()].compactMap { $0 }
            }
            print("STAGE: authorized exact virtual buses and all-device idle state confirmed; starting two production HAL routes.")
            let clock = ContinuousClock(); let ioStart = clock.now
            liveStarted = ioStart
            try forward.start(normal, routeChanged: changed); try reverse.start(peer, routeChanged: changed)
            let deadline = ioStart.advanced(by: .seconds(28))
            let baselineEnd = clock.now.advanced(by: .milliseconds(500))
            var baselineFrames = [0, 0]
            while clock.now < baselineEnd {
                try await Task.sleep(for: .milliseconds(20))
                if let error = state.error { throw VoiceBridgeError.route(error) }
                try forward.verifyDevices(); try reverse.verifyDevices()
                for (index, audio) in [forward, reverse].enumerated() {
                    let samples = try audio.capture.drain().flatMap { try PCM16.floats($0) }
                    baselineFrames[index] += samples.count
                    guard samples.isEmpty || LoopbackClassifier.rms(samples) <= 0.0005 else { throw VoiceBridgeError.route("Bus carries unexpected audio; synthetic run stopped.") }
                }
            }
            guard baselineFrames.allSatisfy({ $0 >= 8000 }) else { throw VoiceBridgeError.route("Insufficient baseline capture coverage; no tones sent.") }
            report["baselineCapturedFrames"] = baselineFrames
            let toneStart = clock.now; let toneEnd = deadline.advanced(by: .seconds(-2))
            var nextTone = toneStart, nextMeasure = toneStart.advanced(by: .seconds(2))
            var offset = 0, tick = 0, twoSamples: [Float] = [], sixteenSamples: [Float] = []
            var windows: [[String: Any]] = []
            while clock.now < deadline {
                if let error = state.error { throw VoiceBridgeError.route(error) }
                // Preload 600ms; thereafter maintain 400–600ms of queued lead across timer jitter.
                while nextTone <= clock.now.advanced(by: .milliseconds(400)) && nextTone < toneEnd {
                    try reverse.play(tone(frequency: 730, offset: offset), item: "reverse730", index: 0)
                    try forward.play(tone(frequency: 997, offset: offset), item: "forward997", index: 0)
                    offset += 4800; nextTone = nextTone.advanced(by: .milliseconds(200))
                }
                twoSamples += try forward.capture.drain().flatMap { try PCM16.floats($0) }
                sixteenSamples += try reverse.capture.drain().flatMap { try PCM16.floats($0) }
                if twoSamples.count > 48_000 { twoSamples.removeFirst(twoSamples.count - 48_000) }
                if sixteenSamples.count > 48_000 { sixteenSamples.removeFirst(sixteenSamples.count - 48_000) }
                tick += 1
                if tick % 5 == 0 { try forward.verifyDevices(); try reverse.verifyDevices() }
                if clock.now >= nextMeasure && nextMeasure < toneEnd {
                    guard twoSamples.count >= 24_000, sixteenSamples.count >= 24_000 else { throw VoiceBridgeError.route("Insufficient native captured signal.") }
                    let twoWindow = Array(twoSamples.suffix(24_000)), sixteenWindow = Array(sixteenSamples.suffix(24_000))
                    let twoResult = HALToneClassifier.measure(twoWindow, frequency: 730, foreignFrequency: 997)
                    let sixteenResult = HALToneClassifier.measure(sixteenWindow, frequency: 997, foreignFrequency: 730)
                    windows.append(["twoChannel": metrics(twoResult), "sixteenChannel": metrics(sixteenResult)])
                    guard twoResult.passed, sixteenResult.passed else { report["windows"] = windows; throw VoiceBridgeError.route("Synthetic gain, continuity, correlation or cross-bus isolation check failed.") }
                    nextMeasure = nextMeasure.advanced(by: .seconds(1))
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            if let error = state.error { throw VoiceBridgeError.route(error) }
            try forward.verifyDevices(); try reverse.verifyDevices()
            let first = forward.interrupt(), second = reverse.interrupt()
            guard let first, let second, first.frames == offset, second.frames == offset, windows.count >= 20 else {
                throw VoiceBridgeError.route("Native playback progress did not confirm the bounded whole-chunk budget.")
            }
            report["windows"] = windows; report["wireFramesScheduledPerBus"] = offset
            report["forwardWireFramesConfirmed"] = first.frames; report["reverseWireFramesConfirmed"] = second.frames
            report["queuedLeadMilliseconds"] = [400, 600]; report["toneDurationSeconds"] = Double(offset) / 24_000
            report["localMetricsPassed"] = true; passed = true
        } catch { report["error"] = error.localizedDescription }
        state.cleanupErrors += [forward.stop(), reverse.stop()].compactMap { $0 }
        if let liveStarted {
            let elapsed = liveStarted.duration(to: ContinuousClock.now).components
            report["elapsedIncludingOwnedCleanupSeconds"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        if !state.cleanupErrors.isEmpty { report["cleanupErrors"] = state.cleanupErrors; passed = false }
        do {
            // Bounded idle confirmation; records exact before/after IDs even on a transient.
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            var after: Snapshot?
            var firstIdle: Snapshot?
            repeat {
                do {
                    let candidate = try idleSnapshot()
                    if firstIdle == nil { firstIdle = candidate }
                    after = candidate
                    if before == nil || candidate == before || ContinuousClock.now >= cleanupDeadline { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                catch { if ContinuousClock.now >= cleanupDeadline { throw error }; try await Task.sleep(for: .milliseconds(100)) }
            } while true
            report["firstIdleCleanupDeviceIDs"] = firstIdle?.ids; report["firstIdleCleanupDefaults"] = firstIdle?.defaults
            let afterIDs = try ids(); let afterDefaults = try defaults()
            report["deviceIDsAfter"] = afterIDs; report["defaultsAfter"] = afterDefaults; report["allDevicesIdleAfter"] = after != nil
            if let before {
                report["inventoryUnchanged"] = before.ids == afterIDs; report["defaultsUnchanged"] = before.defaults == afterDefaults
                if before.ids != afterIDs || before.defaults != afterDefaults { passed = false }
            }
        } catch {
            report["cleanupVerificationError"] = error.localizedDescription
            report["deviceIDsAfter"] = try? ids(); report["defaultsAfter"] = try? defaults(); passed = false
        }
        report["passed"] = passed
        if let error = state.error { report["notificationError"] = error; report["passed"] = false; passed = false }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: bytes, as: UTF8.self))
        } else { print("FAILURE: invalid numeric metrics; all owned audio routes stopped."); passed = false }
        Foundation.exit(passed ? 0 : 1)
    }
}
