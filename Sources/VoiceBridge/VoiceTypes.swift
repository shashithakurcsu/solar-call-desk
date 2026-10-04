import Foundation

public enum VoiceBridgeMode: String, CaseIterable, Sendable {
    case rehearsal, externalBridge
}

public enum VoiceBridgeState: Equatable, Sendable {
    case idle, connecting, listening, speaking, failed(String)
    public var isActive: Bool {
        switch self { case .connecting, .listening, .speaking: true; default: false }
    }
}

public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let uid: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let isVirtual: Bool
    public init(id: UInt32, name: String, uid: String, inputChannels: Int, outputChannels: Int, isVirtual: Bool = false) {
        self.id = id; self.name = name; self.uid = uid
        self.inputChannels = inputChannels; self.outputChannels = outputChannels
        self.isVirtual = isVirtual
    }
}

public struct VoiceBridgeConfiguration: Sendable {
    public var inputDeviceID: UInt32
    public var outputDeviceID: UInt32
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    public var mode: VoiceBridgeMode
    public var instructions: String
    public var model: String
    public var voice: String
    public var externalRoutingAcknowledged: Bool
    public init(inputDeviceID: UInt32, outputDeviceID: UInt32, mode: VoiceBridgeMode,
                instructions: String, model: String = "gpt-realtime-2.1", voice: String = "marin",
                externalRoutingAcknowledged: Bool = false, inputDeviceUID: String? = nil, outputDeviceUID: String? = nil) {
        self.inputDeviceID = inputDeviceID; self.outputDeviceID = outputDeviceID
        self.mode = mode; self.instructions = instructions; self.model = model; self.voice = voice
        self.externalRoutingAcknowledged = externalRoutingAcknowledged
        self.inputDeviceUID = inputDeviceUID; self.outputDeviceUID = outputDeviceUID
    }
    public func validate(devices: [AudioDevice]) throws {
        guard let input = devices.first(where: { $0.id == inputDeviceID }), input.inputChannels > 0,
              let output = devices.first(where: { $0.id == outputDeviceID }), output.outputChannels > 0 else {
            throw VoiceBridgeError.route("Selected audio devices are unavailable. Choose devices again.")
        }
        guard inputDeviceUID == input.uid, outputDeviceUID == output.uid else {
            throw VoiceBridgeError.route("Selected device identity changed or was not pinned. Refresh and choose devices again.")
        }
        if mode == .externalBridge && (input.id == output.id || input.uid == output.uid) {
            throw VoiceBridgeError.route("External bridge requires two separate devices to prevent a feedback loop.")
        }
        if mode == .externalBridge && (!input.isVirtual || !output.isVirtual || !externalRoutingAcknowledged) {
            throw VoiceBridgeError.route("External bridge needs two virtual devices and acknowledgment that independent, isolated buses were configured. WhatsApp routing is unverified.")
        }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.isEmpty, model.count < 128, !voice.isEmpty else {
            throw VoiceBridgeError.configuration("Enter instructions and a valid Realtime model and voice.")
        }
    }
}

public struct VoiceTranscript: Identifiable, Equatable, Sendable {
    public enum Speaker: String, Sendable { case caller, assistant }
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    public init(speaker: Speaker, text: String) { self.id = UUID(); self.speaker = speaker; self.text = text }
}

public enum VoiceBridgeError: Error, LocalizedError, Equatable, Sendable {
    case configuration(String), route(String), protocolViolation(String), bufferOverflow, queueOverflow(String), microphoneDenied
    public var errorDescription: String? {
        switch self {
        case .configuration(let s), .route(let s), .protocolViolation(let s), .queueOverflow(let s): s
        case .bufferOverflow: "Audio queue exceeded its limit. Session stopped to avoid delayed audio."
        case .microphoneDenied: "Microphone access was denied. Allow access in System Settings before starting again."
        }
    }
}
