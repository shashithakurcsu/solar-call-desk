// Read-only preflight. Never requests authorization, creates an audio engine,
// starts I/O, changes defaults, or reads/writes audio samples.
import AVFoundation
import CoreAudio
import Foundation

enum PreflightFailure: Error { case query(String, OSStatus), invalidSize(String, UInt32) }

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func check(_ status: OSStatus, _ label: String) throws {
    guard status == noErr else { throw PreflightFailure.query(label, status) }
}
func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var key = address(selector); var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    try check(AudioObjectGetPropertyData(id, &key, 0, nil, &size, &value), "scalar \(id)/\(selector)")
    return value
}
func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var key = address(selector); var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(id, &key, 0, nil, &size, &value), "string \(id)/\(selector)")
    guard let value else { throw PreflightFailure.invalidSize("missing string", size) }
    return value.takeRetainedValue() as String
}
func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) throws -> Int {
    var key = address(kAudioDevicePropertyStreamConfiguration, scope); var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &key, 0, nil, &size), "stream configuration size \(id)")
    guard size > 0 else { return 0 }
    // Empty scopes legally return only the buffer count plus alignment (8 bytes).
    guard size >= MemoryLayout<UInt32>.size, size <= 65_536 else {
        throw PreflightFailure.invalidSize("stream configuration \(id)", size)
    }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try check(AudioObjectGetPropertyData(id, &key, 0, nil, &size, memory), "stream configuration \(id)")
    return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func deviceIDs() throws -> [AudioDeviceID] {
    var key = address(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size), "device inventory size")
    guard size > 0 else { return [] }
    guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0, size <= 65_536 else {
        throw PreflightFailure.invalidSize("device inventory", size)
    }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    try ids.withUnsafeMutableBytes { raw in
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, raw.baseAddress!), "device inventory")
    }
    return ids
}
func defaults() throws -> [String: UInt32] {
    try ["input": scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
         "output": scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
         "systemOutput": scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)]
}

let auth = AVCaptureDevice.authorizationStatus(for: .audio)
let authName: String
switch auth {
case .authorized: authName = "authorized"
case .notDetermined: authName = "notDetermined"
case .denied: authName = "denied"
case .restricted: authName = "restricted"
@unknown default: authName = "unknown"
}
var report: [String: Any] = ["microphoneAuthorization": authName, "permissionRequested": false, "audioIOStarted": false]
do {
    let before = try defaults(); let ids = try deviceIDs()
    let devices: [[String: Any]] = try ids.map { id in
        ["id": id, "name": try string(id, kAudioObjectPropertyName), "uid": try string(id, kAudioDevicePropertyDeviceUID),
         "alive": try scalar(id, kAudioDevicePropertyDeviceIsAlive) != 0,
         "virtual": try scalar(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual,
         "inputChannels": try channels(id, kAudioDevicePropertyScopeInput),
         "outputChannels": try channels(id, kAudioDevicePropertyScopeOutput),
         "runningSomewhere": try scalar(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0]
    }
    let after = try defaults()
    report["devices"] = devices; report["defaultsBefore"] = before; report["defaultsAfter"] = after
    report["defaultsUnchanged"] = before == after
    report["allDevicesIdle"] = !devices.isEmpty && devices.allSatisfy { $0["runningSomewhere"] as? Bool == false }
    report["requiredPrimaryDevicesReady"] = [("BlackHole2ch_UID", 2), ("BlackHole16ch_UID", 16)].allSatisfy { uid, count in
        let matches = devices.filter { $0["uid"] as? String == uid }
        return matches.count == 1 && matches[0]["alive"] as? Bool == true && matches[0]["virtual"] as? Bool == true
            && matches[0]["inputChannels"] as? Int == count && matches[0]["outputChannels"] as? Int == count
            && matches[0]["runningSomewhere"] as? Bool == false
    }
    report["eligibleForReviewedDiagnostic"] = auth == .authorized && before == after
        && report["allDevicesIdle"] as? Bool == true && report["requiredPrimaryDevicesReady"] as? Bool == true
} catch {
    report["queryError"] = String(describing: error); report["eligibleForReviewedDiagnostic"] = false
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
