// Separate, explicitly authorized synthetic timing probe. No API, calling app,
// physical route, permission request, settings write, or audio file is used.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

@MainActor private final class TimingState {
    var error: String?
    var normal: NativeExternalAudio?
    var peer: NativeExternalAudio?
}

@main struct RunHALTimingTest {
    struct Inventory: Equatable { let ids: [UInt32]; let defaults: [UInt32] }
    static func inventory(requireIdle: Bool) throws -> Inventory {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw VoiceBridgeError.configuration("Existing audio permission is required; no permission is requested.")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try AudioDeviceCatalog.check(AudioObjectGetPropertyDataSize(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0, size <= 65_536, size.isMultiple(of: 4) else { throw VoiceBridgeError.route("Invalid device inventory.") }
        var ids = [UInt32](repeating: 0, count: Int(size / 4))
        try ids.withUnsafeMutableBytes {
            try AudioDeviceCatalog.check(AudioObjectGetPropertyData(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!))
        }
        if requireIdle {
            for id in ids where try AudioDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 {
                throw VoiceBridgeError.route("Device \(id) is already in use; test not started.")
            }
        }
        let defaults = try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice].map { try AudioDeviceCatalog.scalar(UInt32(kAudioObjectSystemObject), $0) }
        return Inventory(ids: ids.sorted(), defaults: defaults)
    }
    static func tone(_ frequency: Double, offset: Int, frames: Int = 2400) -> Data {
        var result = Data(capacity: frames * 2)
        for index in offset..<(offset + frames) {
            let sample = Int16((32768 * LoopbackClassifier.amplitude * sin(2 * .pi * frequency * Double(index) / 24000)).rounded())
            let bits = UInt16(bitPattern: sample)
            result.append(UInt8(bits & 255)); result.append(UInt8(bits >> 8))
        }
        return result
    }
    static func diagnostics(_ value: HALTimelineDiagnostics) -> [String: Any] {
        var result: [String: Any] = ["recoveredIdleDiscontinuities": value.recoveredIdleDiscontinuities]
        if let event = value.firstRecoveredEvent { result["firstRecoveredEvent"] = event }
        if let fault = value.firstFault { result["firstFault"] = fault }
        return result
    }
    @MainActor static func main() async {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--run-reviewed-timing-test"] else {
            print("ABORT: explicit --run-reviewed-timing-test required; no audio started."); Foundation.exit(2)
        }
        let state = TimingState()
        var report: [String: Any] = ["scope": "90-second primary virtual-bus timing-pattern test; no Phone or API",
            "permissionRequested": false, "networkUsed": false, "audioFilesWritten": false,
            "phases": ["0–20s solo idle", "20–30s peer joins, idle", "30–55s bursty tones with gaps",
                       "55–65s peer leaves, solo idle", "65–70s fresh peer rejoins, idle", "70–85s bursty tones", "85–90s drain"]]
        var initial: Inventory?
        var passed = false
        var cleanup: [String] = []
        var scheduled = [0, 0], totalSent = [0, 0], tonalWindows = [0, 0], quietWindows = [0, 0]
        var capturedFrames = [0, 0]
        var phaseSnapshots: [[String: Any]] = []
        let clock = ContinuousClock()
        var started: ContinuousClock.Instant?
        do {
            initial = try inventory(requireIdle: true)
            let devices = try AudioDeviceCatalog.devices()
            func selected(_ uid: String, _ channels: Int) throws -> AudioDevice {
                let matches = devices.filter { $0.uid == uid }
                guard matches.count == 1, let device = matches.first, device.isVirtual,
                      device.inputChannels == channels, device.outputChannels == channels else {
                    throw VoiceBridgeError.route("Exact primary \(uid), \(channels) channels required.")
                }
                return device
            }
            let two = try selected("BlackHole2ch_UID", 2), sixteen = try selected("BlackHole16ch_UID", 16)
            func config(_ input: AudioDevice, _ output: AudioDevice) -> VoiceBridgeConfiguration {
                VoiceBridgeConfiguration(inputDeviceID: input.id, outputDeviceID: output.id, mode: .externalBridge,
                    instructions: "Synthetic local timing probe", externalRoutingAcknowledged: true,
                    inputDeviceUID: input.uid, outputDeviceUID: output.uid)
            }
            let normalConfig = config(two, sixteen), peerConfig = config(sixteen, two)
            try normalConfig.validate(devices: devices); try peerConfig.validate(devices: devices)
            guard try inventory(requireIdle: true) == initial else { throw VoiceBridgeError.route("Preflight changed.") }
            let changed: @MainActor @Sendable (String) -> Void = { message in
                if state.error == nil { state.error = message }
            }
            let normal = NativeExternalAudio(); state.normal = normal
            started = clock.now
            try normal.start(normalConfig, routeChanged: changed)
            report["lastStage"] = "solo idle"
            print("STAGE: solo idle; exact primary virtual buses only.")
            let start = started!
            var peerJoined = false, peerLeft = false, peerRejoined = false
            var windows: [[Float]] = [[], []]
            var nextBurst = 30.0, burstIndex = 0, tick = 0, events: [(Double, Int)] = []
            while start.duration(to: clock.now) < .seconds(90) {
                let parts = start.duration(to: clock.now).components
                let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                if let error = state.error { throw VoiceBridgeError.route(error) }
                if elapsed >= 20 && !peerJoined {
                    let peer = NativeExternalAudio(); state.peer = peer
                    try peer.start(peerConfig, routeChanged: changed); peerJoined = true
                    report["lastStage"] = "peer joined, idle"
                    print("STAGE: peer joined; both routes idle.")
                }
                if elapsed >= 55 && !peerLeft {
                    guard let peer = state.peer, let result = peer.interrupt(), result.frames == scheduled[1] else {
                        throw VoiceBridgeError.route("First peer did not finish its scheduled speech.")
                    }
                    phaseSnapshots.append(["phase": "peer leaving", "normal": diagnostics(normal.timelineDiagnostics()), "peer": diagnostics(peer.timelineDiagnostics())])
                    if let error = peer.stop() { throw VoiceBridgeError.route(error) }
                    state.peer = nil; scheduled[1] = 0; peerLeft = true; windows[1] = []
                    report["lastStage"] = "peer left, solo idle"
                    print("STAGE: peer left; solo idle.")
                }
                if elapsed >= 65 && !peerRejoined {
                    let peer = NativeExternalAudio(); state.peer = peer
                    try peer.start(peerConfig, routeChanged: changed); peerRejoined = true; nextBurst = 70
                    report["lastStage"] = "fresh peer rejoined"
                    print("STAGE: fresh peer rejoined; idle then bursty tones.")
                }
                let inBurstPhase = (elapsed >= 30 && elapsed < 53) || (elapsed >= 70 && elapsed < 83)
                if inBurstPhase && elapsed >= nextBurst {
                    report["lastStage"] = peerRejoined ? "second burst phase" : "first burst phase"
                    // 100ms chunks arrive after 0, 170 and 430ms: deliberately empty
                    // playback queues between fragments, then a conversational pause.
                    for delay in [0.0, 0.17, 0.43] {
                        events.append((nextBurst + delay, 0)); events.append((nextBurst + delay + 0.8, 1))
                    }
                    nextBurst += 2.5; burstIndex += 1
                    if burstIndex == 1 { print("STAGE: alternating fragmented synthetic speech with silence between chunks.") }
                }
                events.sort { $0.0 < $1.0 }
                while let event = events.first, event.0 <= elapsed {
                    events.removeFirst()
                    guard let route = event.1 == 0 ? state.normal : state.peer else { throw VoiceBridgeError.route("Peer unavailable for planned fragment.") }
                    try route.play(tone(event.1 == 0 ? 1000 : 750, offset: totalSent[event.1]), item: "synthetic-\(event.1)", index: 0)
                    scheduled[event.1] += 2400; totalSent[event.1] += 2400
                }
                tick += 1
                for (index, route) in [state.normal, state.peer].enumerated() {
                    guard let route else { continue }
                    if tick % 5 == 0 { try route.verify() }
                    let samples = try route.capture.drain().flatMap { try PCM16.floats($0) }
                    capturedFrames[index] += samples.count
                    windows[index] += samples
                    if windows[index].count > 1536 { windows[index].removeFirst(windows[index].count - 1536) }
                    if windows[index].count == 1536 {
                        let rms = LoopbackClassifier.rms(windows[index])
                        if rms < 0.0005 { quietWindows[index] += 1 }
                        if rms > 0.01 {
                            // Both frequencies have whole cycles in this 64ms window.
                            let value = HALToneClassifier.measure(windows[index], frequency: index == 0 ? 750 : 1000, foreignFrequency: index == 0 ? 1000 : 750)
                            if value.correlation > 0.98 && value.leakageRatio < 0.03 { tonalWindows[index] += 1 }
                        }
                        if elapsed < 30 && rms > 0.0005 { throw VoiceBridgeError.route("Unexpected audio during silent baseline; stopped.") }
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            if let error = state.error { throw VoiceBridgeError.route(error) }
            for (index, route) in [state.normal, state.peer].enumerated() {
                guard let route else { throw VoiceBridgeError.route("Final route missing.") }
                try route.verify()
                guard let result = route.interrupt(), result.frames == scheduled[index] else { throw VoiceBridgeError.route("Scheduled speech did not fully drain.") }
            }
            guard tonalWindows.allSatisfy({ $0 >= 10 }), quietWindows.allSatisfy({ $0 >= 100 }) else {
                throw VoiceBridgeError.route("Insufficient tone or silence observations.")
            }
            passed = true
        } catch { report["error"] = error.localizedDescription }
        report["phaseSnapshots"] = phaseSnapshots; report["wireFramesSent"] = totalSent
        report["tonalWindows"] = tonalWindows; report["quietWindows"] = quietWindows; report["capturedFrames"] = capturedFrames
        if let normal = state.normal { report["normalTiming"] = diagnostics(normal.timelineDiagnostics()) }
        if let peer = state.peer { report["peerTiming"] = diagnostics(peer.timelineDiagnostics()) }
        cleanup += [state.normal?.stop(), state.peer?.stop()].compactMap { $0 }
        report["cleanupErrors"] = cleanup
        if !cleanup.isEmpty { passed = false }
        do {
            let deadline = clock.now.advanced(by: .seconds(3))
            var after: Inventory?
            repeat {
                do { after = try inventory(requireIdle: true) }
                catch {
                    if clock.now >= deadline { throw error }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } while after == nil
            guard let after else { throw VoiceBridgeError.route("Idle cleanup not confirmed.") }
            report["allDevicesIdleAfter"] = true
            report["deviceIDsBefore"] = initial?.ids; report["deviceIDsAfter"] = after.ids
            report["defaultsBefore"] = initial?.defaults; report["defaultsAfter"] = after.defaults
            report["inventoryAndDefaultsUnchanged"] = initial == after
            if initial != after { passed = false }
        } catch { report["cleanupVerificationError"] = error.localizedDescription; passed = false }
        if let started {
            let elapsed = started.duration(to: clock.now).components
            report["elapsedSeconds"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        report["passed"] = passed
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        } else { print("FAILURE: timing report could not be encoded."); passed = false }
        Foundation.exit(passed ? 0 : 1)
    }
}
