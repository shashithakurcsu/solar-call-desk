// Read-only Core Audio process/device metadata. No audio starts or settings writes.
import CoreAudio
import Foundation

func address(_ selector: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func scalar(_ id: UInt32, _ selector: UInt32) throws -> UInt32 {
    var key = address(selector), value: UInt32 = 0, size: UInt32 = 4
    let status = AudioObjectGetPropertyData(id, &key, 0, nil, &size, &value)
    guard status == noErr, size == 4 else { throw NSError(domain: "ReadOnlyCoreAudio", code: Int(status)) }
    return value
}
func array(_ id: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
    var key = address(selector), size: UInt32 = 0
    key.mScope = scope
    let status = AudioObjectGetPropertyDataSize(id, &key, 0, nil, &size)
    guard status == noErr, size <= 65536, size.isMultiple(of: 4) else { throw NSError(domain: "ReadOnlyCoreAudio", code: Int(status)) }
    if size == 0 { return [] }
    let capacity = size
    var result = [UInt32](repeating: 0, count: Int(size / 4))
    let read = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &key, 0, nil, &size, $0.baseAddress!) }
    guard read == noErr, size <= capacity, size.isMultiple(of: 4) else { throw NSError(domain: "ReadOnlyCoreAudio", code: Int(read)) }
    return Array(result.prefix(Int(size / 4)))
}
func bundle(_ id: UInt32) -> String? {
    var key = address(kAudioProcessPropertyBundleID), value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &key, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}
guard CommandLine.arguments.count == 2, let device = UInt32(CommandLine.arguments[1]) else { exit(2) }
var matches: [[String: Any]] = [], unreadable = 0
for object in try array(UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
    do {
        guard try scalar(object, kAudioProcessPropertyIsRunningOutput) != 0,
              try array(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput).contains(device) else { continue }
        var match: [String: Any] = ["processObject": object, "pid": try scalar(object, kAudioProcessPropertyPID), "outputRunning": true]
        match["bundleID"] = bundle(object)
        matches.append(match)
    } catch { unreadable += 1 }
}
let report: [String: Any] = ["targetDeviceID": device, "matchingOutputProcesses": matches,
    "unreadableProcesses": unreadable, "audioIOStarted": false, "settingsChanged": false]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
