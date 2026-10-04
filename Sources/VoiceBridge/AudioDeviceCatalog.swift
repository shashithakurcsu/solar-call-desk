import CoreAudio
import Foundation

public enum AudioDeviceCatalog {
    public static func devices() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try ids.withUnsafeMutableBytes { raw in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, raw.baseAddress!))
        }
        return try ids.compactMap { id in
            guard try scalar(id, kAudioDevicePropertyDeviceIsAlive) != 0 else { return nil }
            let input = try channels(id, scope: kAudioDevicePropertyScopeInput)
            let output = try channels(id, scope: kAudioDevicePropertyScopeOutput)
            guard input + output > 0 else { return nil }
            return AudioDevice(id: id, name: try string(id, kAudioObjectPropertyName),
                               uid: try string(id, kAudioDevicePropertyDeviceUID),
                               inputChannels: input, outputChannels: output,
                               isVirtual: try scalar(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw VoiceBridgeError.route("CoreAudio device query or routing failed (\(status)).") }
    }
    static func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        return value
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        guard let value else { throw VoiceBridgeError.route("CoreAudio returned no device identity.") }
        return value.takeRetainedValue() as String
    }
    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
        guard size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory))
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Notifications trigger revalidation; only actual selected-property changes stop the session.
@MainActor final class AudioRouteWatch {
    private struct Entry {
        let id: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock?
        let baseline: AudioRoutePropertyValue?
    }
    private var entries: [Entry] = []
    func start(input: UInt32, output: UInt32, changed: @escaping @MainActor @Sendable (String) -> Void) throws {
        let selections: [(UInt32, UInt32, UInt32)] = [
            (UInt32(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal),
            (input, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (output, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (input, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (output, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (input, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput),
            (output, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput),
            (input, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeInput),
            (output, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        ]
        var installed = Set<String>()
        for (id, selector, scope) in selections {
            guard installed.insert("\(id)/\(selector)/\(scope)").inserted else { continue }
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let available = AudioObjectHasProperty(id, &address)
            let baseline = id == UInt32(kAudioObjectSystemObject) ? nil : try Self.value(id: id, address: address)
            let block: AudioObjectPropertyListenerBlock = { count, addresses in
                // Copy borrowed callback addresses before returning or hopping to MainActor.
                let event = "CoreAudio device \(id): " + UnsafeBufferPointer(start: addresses, count: Int(count))
                    .map { Self.describe($0) }.joined(separator: ", ")
                Task { @MainActor in changed(event) }
            }
            if available { try AudioDeviceCatalog.check(AudioObjectAddPropertyListenerBlock(id, &address, .main, block)) }
            entries.append(Entry(id: id, address: address, block: available ? block : nil, baseline: baseline))
        }
    }
    func verify(context: String) throws {
        for entry in entries {
            // Device inventory may change harmlessly. The owner checks its selected identities.
            guard let baseline = entry.baseline else { continue }
            let actual: AudioRoutePropertyValue
            do { actual = try Self.value(id: entry.id, address: entry.address) }
            catch { throw VoiceBridgeError.route("\(context): querying device \(entry.id) \(Self.describe(entry.address)) failed: \(error.localizedDescription)") }
            try AudioRouteIntegrity.equal(baseline, actual, property: "device \(entry.id) \(Self.describe(entry.address))", context: context)
        }
    }
    private static func value(id: AudioObjectID, address original: AudioObjectPropertyAddress) throws -> AudioRoutePropertyValue {
        var address = original
        guard AudioObjectHasProperty(id, &address) else { return .missing }
        if address.mSelector == kAudioDevicePropertyStreamConfiguration {
            var size: UInt32 = 0
            try AudioDeviceCatalog.check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
            guard size >= MemoryLayout<AudioBufferList>.size, size <= 65_536 else {
                throw VoiceBridgeError.route("Device \(id) returned an invalid stream configuration size \(size).")
            }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            try AudioDeviceCatalog.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory))
            return .channels(try Self.topology(memory.assumingMemoryBound(to: AudioBufferList.self), byteCount: Int(size)))
        }
        if address.mSelector == kAudioDevicePropertyNominalSampleRate {
            var value = 0.0; var size = UInt32(MemoryLayout<Double>.size)
            try AudioDeviceCatalog.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
            return .rate(value)
        }
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        try AudioDeviceCatalog.check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        return .unsigned(value)
    }
    nonisolated static func topology(_ list: UnsafePointer<AudioBufferList>, byteCount: Int) throws -> [UInt32] {
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard byteCount >= offset, Int(list.pointee.mNumberBuffers) <= (byteCount - offset) / MemoryLayout<AudioBuffer>.stride else {
            throw VoiceBridgeError.route("Audio stream configuration exceeds its returned buffer size.")
        }
        return UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)).map(\.mNumberChannels)
    }
    nonisolated private static func describe(_ address: AudioObjectPropertyAddress) -> String {
        let property: String
        switch address.mSelector {
        case kAudioHardwarePropertyDevices: property = "device inventory"
        case kAudioDevicePropertyDeviceIsAlive: property = "alive"
        case kAudioDevicePropertyNominalSampleRate: property = "nominal sample rate"
        case kAudioDevicePropertyStreamConfiguration: property = "stream configuration"
        case kAudioDevicePropertyDataSource: property = "data source"
        default: property = "property \(address.mSelector)"
        }
        return "\(property) (scope \(address.mScope), element \(address.mElement))"
    }
    func stop() {
        for var entry in entries {
            if let block = entry.block { AudioObjectRemovePropertyListenerBlock(entry.id, &entry.address, .main, block) }
        }
        entries.removeAll()
    }
}
