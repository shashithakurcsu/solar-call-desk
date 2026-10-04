import Foundation

@MainActor protocol VoiceAudioEndpoint: AnyObject {
    var capture: PCMQueue { get }
    var onDrained: (() -> Void)? { get set }
    var queuedPlaybackFrames: Int64 { get }
    func verifyDevices(stage: String, requireRunning: Bool?) throws
    func play(_ data: Data, item: String, index: Int) throws
    func interrupt() -> (item: String, index: Int, frames: Int64)?
    @discardableResult func stop() -> String?
}

/// One byte store per queue prevents tiny server/capture fragments multiplying allocations.
/// Consumed prefixes are compacted amortized, and before any append exceeding the storage bound.
struct OrderedPCMBuffer {
    private var storage = Data()
    private var offset = 0
    var count: Int { storage.count - offset }
    mutating func append(_ data: Data, storageLimit: Int) {
        if offset > 0 && (offset >= 65_536 && offset >= storage.count / 2 || storage.count + data.count > storageLimit) {
            storage = Data(storage.dropFirst(offset)); offset = 0
        }
        storage.append(data)
    }
    mutating func take(_ bytes: Int) -> Data {
        let amount = min(bytes, count)
        let result = storage.subdata(in: offset..<(offset + amount)); offset += amount
        if offset == storage.count { storage.removeAll(keepingCapacity: true); offset = 0 }
        return result
    }
    mutating func clear() { storage = Data(); offset = 0 }
}

struct VoiceOutgoingBuffer {
    static let byteLimit = 160_000
    static let messageLimit = 128
    static let batchBytes = 1_920 // 40 ms of PCM16 mono at 24 kHz.
    private var pcm = OrderedPCMBuffer()
    private var controls: [String] = []
    private var setup: String?
    private var controlBytes = 0
    private var flushTail = false
    private(set) var inFlightBytes = 0
    private var inFlightControl = false
    private var controlReservedBytes: Int { controlBytes + (inFlightControl ? inFlightBytes : 0) }
    private var inputReservedBytes: Int { reservedBytes - controlReservedBytes }
    private var controlReservedCount: Int { controls.count + (inFlightControl ? 1 : 0) }
    private var inputReservedCount: Int { reservedMessages - controlReservedCount }
    var pendingPCMBytes: Int { pcm.count }
    var pendingControlCount: Int { controls.count }
    var reservedMessages: Int { (setup == nil ? 0 : 1) + controls.count + (pcm.count + Self.batchBytes - 1) / Self.batchBytes + (inFlightBytes > 0 ? 1 : 0) }
    // 128 bytes conservatively covers fixed JSON keys and the 36-character event UUID.
    // Input batches are multiples of two; charging each complete/partial batch includes base64 padding.
    var reservedBytes: Int {
        let full = pcm.count / Self.batchBytes, tail = pcm.count % Self.batchBytes
        return (setup?.utf8.count ?? 0) + inFlightBytes + controlBytes + full * (Self.batchBytes / 3 * 4 + 128) + (tail > 0 ? (tail + 2) / 3 * 4 + 128 : 0)
    }
    mutating func appendPCM(_ data: Data) throws {
        guard data.count.isMultiple(of: 2) else { throw VoiceBridgeError.protocolViolation("Odd captured PCM size.") }
        guard !data.isEmpty else { return }
        // Bound before allocation; base64 expansion alone is a lower bound on the charge.
        guard data.count <= Self.byteLimit, inputReservedBytes + (data.count + 2) / 3 * 4 <= Self.byteLimit - 16_000 else {
            throw overflow(incoming: data.count)
        }
        pcm.append(data, storageLimit: Self.byteLimit)
        try validate(incoming: data.count)
    }
    mutating func appendSetup(_ text: String) throws {
        guard reservedBytes == 0, text.utf8.count <= Self.byteLimit else {
            throw VoiceBridgeError.queueOverflow("Outgoing configuration queue exceeded its bound: queued=\(reservedBytes)bytes, incoming=\(text.utf8.count)bytes, limit=160000bytes.")
        }
        setup = text
    }
    mutating func appendControl(_ text: String) throws {
        // Reserve a separate bounded control lane; do not allow cancel/truncate to be
        // rejected merely because unsent capture occupies the normal input budget.
        guard controlReservedCount < 16, controlReservedBytes + text.utf8.count <= 16_000, reservedBytes + text.utf8.count <= Self.byteLimit, reservedMessages < Self.messageLimit else {
            throw VoiceBridgeError.queueOverflow("Outgoing control queue exceeded its bound: reserved=\(controlReservedBytes)bytes/\(controlReservedCount)messages, inFlight=\(inFlightControl ? inFlightBytes : 0)bytes, incoming=\(text.utf8.count)bytes, limit=16000bytes/16messages.")
        }
        controls.append(text); controlBytes += text.utf8.count
    }
    mutating func flushInputTail() { flushTail = true }
    mutating func next() throws -> String? {
        guard inFlightBytes == 0 else { return nil }
        let result: String
        if !controls.isEmpty { result = controls.removeFirst(); controlBytes -= result.utf8.count; inFlightControl = true }
        else if let configuration = setup { result = configuration; setup = nil; inFlightControl = false }
        else if pcm.count >= Self.batchBytes || flushTail && pcm.count > 0 {
            inFlightControl = false
            result = try RealtimeProtocol.append(pcm.take(Self.batchBytes))
            if pcm.count == 0 { flushTail = false }
        } else { return nil }
        inFlightBytes = result.utf8.count
        return result
    }
    mutating func sent() { inFlightBytes = 0; inFlightControl = false }
    mutating func clear() { pcm.clear(); setup = nil; controls.removeAll(); controlBytes = 0; flushTail = false; inFlightBytes = 0; inFlightControl = false }
    private func validate(incoming: Int) throws {
        guard inputReservedBytes <= Self.byteLimit - 16_000, inputReservedCount <= Self.messageLimit - 16 else { throw overflow(incoming: incoming) }
    }
    private func overflow(incoming: Int) -> VoiceBridgeError {
        .queueOverflow("Outgoing capture queue exceeded its bound: reserved=\(reservedBytes)bytes/\(reservedMessages)messages, inFlight=\(inFlightBytes)bytes, pendingPCM=\(pcm.count)bytes, incomingPCM=\(incoming)bytes, limit=160000bytes/128messages. Session stopped to avoid delayed input.")
    }
}

struct ResponseAudioBuffer {
    static let totalFrameLimit: Int64 = 1_440_000 // 60s / 2.88MB of response PCM, including hardware lead.
    static let hardwareLead: Int64 = 12_000 // 0.5 seconds; never fill the backend's 10s safety buffer.
    static let chunkFrames = 960 // Consolidate into 40ms hardware chunks.
    private var pcm = OrderedPCMBuffer()
    private(set) var responseID: String?
    private(set) var itemID: String?
    private(set) var contentIndex = 0
    private(set) var done = false
    var stagedFrames: Int64 { Int64(pcm.count / 2) }
    mutating func append(_ data: Data, response: String, item: String, index: Int, hardwareFrames: Int64) throws -> Bool {
        if let responseID, responseID != response || itemID != item || contentIndex != index {
            guard stagedFrames + hardwareFrames == 0 else { throw VoiceBridgeError.protocolViolation("Overlapping response audio items.") }
            clear()
        }
        guard stagedFrames + hardwareFrames + Int64(data.count / 2) <= Self.totalFrameLimit else { return false }
        responseID = response; itemID = item; contentIndex = index
        pcm.append(data, storageLimit: Int(Self.totalFrameLimit * 2)); return true
    }
    mutating func markDone(_ response: String) { if responseID == response { done = true } }
    mutating func take(frames: Int) -> Data { pcm.take(frames * 2) }
    mutating func clear() { pcm.clear(); responseID = nil; itemID = nil; contentIndex = 0; done = false }
}

struct VoiceFlowDiagnostics: Sendable, Equatable {
    let outgoingReservedBytes: Int
    let outgoingReservedMessages: Int
    let inFlightBytes: Int
    let pendingInputBytes: Int
    let stagedOutputFrames: Int64
    let hardwareOutputFrames: Int64
}
