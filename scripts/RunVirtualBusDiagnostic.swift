// Compile with Sources/VoiceBridge/*.swift and -parse-as-library using Swift CLT.
// Executes only the existing synthetic virtual-bus diagnostic. No app identity
// substitution, network, disk PCM, default-device mutations or permission requests.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

@main struct RunVirtualBusDiagnostic {
    struct Snapshot: Equatable {
        let devices: [UInt32]
        let defaults: [UInt32]
    }
    @MainActor static func idleSnapshot() throws -> Snapshot {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw VoiceBridgeError.configuration("Existing microphone authorization is required; permission requests are forbidden in this runner.")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try AudioDeviceCatalog.check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0, size <= 65_536, size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
            throw VoiceBridgeError.route("Device inventory unavailable or invalid; no I/O allowed.")
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try ids.withUnsafeMutableBytes { raw in
            try AudioDeviceCatalog.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, raw.baseAddress!))
        }
        for id in ids {
            guard try AudioDeviceCatalog.scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 else {
                throw VoiceBridgeError.route("Audio device \(id) is in use; no I/O allowed.")
            }
        }
        return Snapshot(devices: ids.sorted(), defaults: try defaultIDs())
    }
    static func defaultIDs() throws -> [UInt32] {
        try [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
             kAudioHardwarePropertyDefaultSystemOutputDevice].map {
            try AudioDeviceCatalog.scalar(AudioObjectID(kAudioObjectSystemObject), $0)
        }
    }
    static func jsonNumber(_ value: Double) -> Any {
        value.isFinite ? value as Any : String(describing: value)
    }
    static func metrics(_ value: VirtualLoopbackMetrics) -> [String: Any] {
        ["ownRMS": jsonNumber(value.ownRMS), "otherRMS": jsonNumber(value.otherRMS), "correlation": jsonNumber(value.correlation),
         "gain": jsonNumber(value.gain), "leakageRatio": jsonNumber(value.leakageRatio), "analyzedFrames": value.analyzedFrames,
         "capturedFrames": value.capturedFrames, "captureSampleRate": value.captureSampleRate, "passed": value.passed]
    }
    @MainActor static func main() async {
        // A deliberate launch argument prevents accidental execution during source inspection.
        guard CommandLine.arguments == [CommandLine.arguments[0], "--run-reviewed-local-virtual-test"] else {
            print("ABORT: explicit --run-reviewed-local-virtual-test argument required; no audio I/O.")
            Foundation.exit(2)
        }
        let diagnostic = VirtualLoopbackDiagnostic()
        var output: [String: Any] = ["permissionRequested": false, "scope": "Synthetic local primary BlackHole first channel pair only; remote phone call status and call-app routing are unverified."]
        var before: Snapshot?
        var exitCode: Int32 = 1
        do {
            let initial = try idleSnapshot(); before = initial
            let devices = try AudioDeviceCatalog.devices()
            func select(_ uid: String) throws -> AudioDevice {
                let matches = devices.filter { $0.uid == uid }
                guard matches.count == 1 else { throw VoiceBridgeError.route("Expected exactly one \(uid).") }
                return matches[0]
            }
            let configuration = try VirtualLoopbackConfiguration(twoChannelDevice: select("BlackHole2ch_UID"),
                sixteenChannelDevice: select("BlackHole16ch_UID"), noActiveCallsAcknowledged: true)
            try configuration.validate(devices: devices)
            guard try idleSnapshot() == initial else {
                throw VoiceBridgeError.route("Inventory or defaults changed during preflight; no I/O allowed.")
            }
            output["defaultsBefore"] = initial.defaults
            output["deviceIDsBefore"] = initial.devices
            output["preflightAllDevicesIdle"] = true
            output["twoChannelUID"] = configuration.twoChannelDevice.uid
            output["sixteenChannelUID"] = configuration.sixteenChannelDevice.uid
            output["twoChannelID"] = configuration.twoChannelDevice.id
            output["sixteenChannelID"] = configuration.sixteenChannelDevice.id
            print("STAGE: existing authorization, all-device idle state and exact primary virtual routes verified; starting guarded diagnostic.")
            diagnostic.start(configuration: configuration, allowPermissionRequest: false)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while diagnostic.state.isActive && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !diagnostic.state.isActive else {
                throw VoiceBridgeError.route("Runner timed out after 20 seconds; all engines stopped.")
            }
            guard diagnostic.state == .completed, let report = diagnostic.result else {
                throw VoiceBridgeError.route(diagnostic.lastError ?? "Diagnostic did not complete.")
            }
            output["passed"] = report.passed
            output["diagnosticPassed"] = report.passed
            output["twoChannel"] = metrics(report.twoChannel)
            output["sixteenChannel"] = metrics(report.sixteenChannel)
            output["hardwareRates"] = ["twoChannelInput": report.twoChannelInputSampleRate,
                "twoChannelOutput": report.twoChannelOutputSampleRate, "sixteenChannelInput": report.sixteenChannelInputSampleRate,
                "sixteenChannelOutput": report.sixteenChannelOutputSampleRate]
            output["diagnosticScope"] = report.scopeDescription
            exitCode = report.passed ? 0 : 1
        } catch {
            output["passed"] = false; output["error"] = error.localizedDescription
        }
        diagnostic.stop()
        do {
            let after = try defaultIDs(); output["defaultsAfter"] = after
            if let before {
                output["defaultsUnchanged"] = before.defaults == after
                if before.defaults != after { output["passed"] = false; exitCode = 1 }
                let afterSnapshot = try idleSnapshot()
                output["deviceIDsAfterCleanup"] = afterSnapshot.devices
                output["allDevicesIdleAfterCleanup"] = true
                let inventoryUnchanged = afterSnapshot.devices == before.devices
                output["inventoryUnchanged"] = inventoryUnchanged
                if !inventoryUnchanged { output["passed"] = false; exitCode = 1 }
            }
        } catch {
            output["cleanupVerificationError"] = error.localizedDescription; output["passed"] = false; exitCode = 1
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("FAILURE: metrics could not be serialized (possibly non-finite); engines stopped.")
            exitCode = 1
        }
        Foundation.exit(exitCode)
    }
}
