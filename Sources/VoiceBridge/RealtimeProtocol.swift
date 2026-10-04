import Foundation

/// Current GA Realtime JSON. The sole local tool closes voice, never a Phone call.
enum RealtimeProtocol {
    static let sampleRate = 24_000
    static func endpoint(model: String) -> URL {
        var components = URLComponents()
        components.scheme = "wss"; components.host = "api.openai.com"; components.path = "/v1/realtime"
        components.queryItems = [.init(name: "model", value: model)]
        return components.url!
    }
    static func sessionUpdate(_ config: VoiceBridgeConfiguration) throws -> String {
        try json([
            "type": "session.update",
            "session": [
                "type": "realtime", "model": config.model, "output_modalities": ["audio"],
                "instructions": config.instructions,
                "tools": [["type": "function", "name": "finish_conversation",
                    "description": "Finish only when the person clearly says goodbye or explicitly says they have nothing else to add. A pause, thank you, or an ordinary reply alone does not end the conversation. Invoke without more speech; the app will say a short goodbye and stop voice unless the person resumes speaking. This cannot hang up Phone or contact anyone.",
                    "parameters": ["type": "object", "properties": [:], "required": [], "additionalProperties": false]]],
                "tool_choice": "auto",
                "audio": [
                    "input": ["format": ["type": "audio/pcm", "rate": sampleRate],
                              "transcription": ["model": "gpt-4o-mini-transcribe"],
                              "turn_detection": ["type": "server_vad", "threshold": 0.5,
                                  "prefix_padding_ms": 300, "silence_duration_ms": 500,
                                  "create_response": true, "interrupt_response": false]],
                    "output": ["format": ["type": "audio/pcm", "rate": sampleRate], "voice": config.voice]
                ]
            ]
        ])
    }
    static func finishCallID(_ response: [String: Any]) throws -> String? {
        guard response["status"] as? String == "completed",
              let output = response["output"] as? [[String: Any]] else { return nil }
        let requests = output.filter { $0["type"] as? String == "function_call" && $0["name"] as? String == "finish_conversation" }
        guard !requests.isEmpty else { return nil }
        guard requests.count == 1, let request = requests.first,
              request["status"] as? String == "completed",
              let call = request["call_id"] as? String, !call.isEmpty, call.utf8.count < 256,
              let arguments = request["arguments"] as? String, arguments.utf8.count <= 256,
              let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any], object.isEmpty else {
            throw VoiceBridgeError.protocolViolation("Invalid conversation-finish request.")
        }
        return call
    }
    static func finishToolResult(callID: String, continuing: Bool = false) throws -> String {
        try json(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID,
            "output": continuing ? "{\"voice_closing\":false,\"reason\":\"person_continued_speaking\",\"phone_hangup\":false}" : "{\"voice_closing\":true,\"phone_hangup\":false}"]])
    }
    static func farewellResponse(token: String) throws -> String {
        try json(["type": "response.create", "response": ["output_modalities": ["audio"], "tool_choice": "none",
            "metadata": ["solar_farewell": token],
            "instructions": "The conversation is complete. Say exactly: Thank you. Goodbye. Do not introduce yourself, add any other words, ask a question, offer help, or claim the Phone call has ended."]])
    }
    static func append(_ pcm: Data) throws -> String {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
            throw VoiceBridgeError.protocolViolation("Invalid PCM16 input.")
        }
        return try json(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }
    static func truncate(itemID: String, contentIndex: Int, playedFrames: Int64) throws -> String {
        try json(["type": "conversation.item.truncate", "item_id": itemID,
                  "content_index": contentIndex, "audio_end_ms": max(0, playedFrames) * 1000 / Int64(sampleRate)])
    }
    static func json(_ object: [String: Any]) throws -> String {
        var object = object
        object["event_id"] = UUID().uuidString
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func parse(_ text: String) throws -> [String: Any] {
        guard text.utf8.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["type"] is String else {
            throw VoiceBridgeError.protocolViolation("Malformed or oversized Realtime event.")
        }
        return object
    }
    static func audio(_ event: [String: Any]) throws -> Data {
        guard let encoded = event["delta"] as? String, let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty, bytes.count.isMultiple(of: 2), bytes.count <= 144_000 else {
            throw VoiceBridgeError.protocolViolation("Invalid PCM16 response audio.")
        }
        return bytes
    }
    static func validateAcknowledgedAudio(_ event: [String: Any]) throws {
        guard let session = event["session"] as? [String: Any], session["type"] as? String == "realtime",
              session["output_modalities"] as? [String] == ["audio"],
              let audio = session["audio"] as? [String: Any],
              let input = audio["input"] as? [String: Any],
              let vad = input["turn_detection"] as? [String: Any], vad["type"] as? String == "server_vad",
              vad["create_response"] as? Bool == true, vad["interrupt_response"] as? Bool == false else {
            throw VoiceBridgeError.protocolViolation("Server did not acknowledge the required audio and turn configuration.")
        }
        for direction in ["input", "output"] {
            guard let settings = audio[direction] as? [String: Any], let format = settings["format"] as? [String: Any],
                  format["type"] as? String == "audio/pcm", format["rate"] as? Int == 24_000 else {
                throw VoiceBridgeError.protocolViolation("Server PCM format differs from 24 kHz PCM16. Audio was not started.")
            }
        }
    }
}

/// PCM is little-endian signed 16-bit mono, as required by Realtime audio/pcm.
enum PCM16 {
    static func floats(_ bytes: Data) throws -> [Float] {
        guard bytes.count.isMultiple(of: 2) else { throw VoiceBridgeError.protocolViolation("Odd PCM byte count.") }
        return bytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 2).map {
                Float(Int16(bitPattern: UInt16(raw[$0]) | (UInt16(raw[$0 + 1]) << 8))) / 32768
            }
        }
    }
}

/// Fixed memory budget shared by audio callback and polling consumer. Overflow is latched, never silently dropped.
final class PCMQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bytes = 0
    private var overflow: String?
    private var closed = false
    private var failure: VoiceBridgeError?
    private let limit: Int
    init(limit: Int = 96_000) { self.limit = limit }
    func push(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, overflow == nil else { return }
        guard bytes + data.count <= limit else { overflow = "Capture PCM queue exceeded its bound: queued=\(bytes)bytes, incoming=\(data.count)bytes, limit=\(limit)bytes (2s at 24kHz PCM16). Session stopped to avoid delayed input."; chunks.removeAll(); bytes = 0; return }
        chunks.append(data); bytes += data.count
    }
    func drain() throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        if let overflow { throw VoiceBridgeError.queueOverflow(overflow) }
        if let failure { throw failure }
        let result = chunks; chunks.removeAll(keepingCapacity: true); bytes = 0
        return result
    }
    func close() { lock.lock(); closed = true; chunks.removeAll(); bytes = 0; lock.unlock() }
    func fail(_ error: VoiceBridgeError) { lock.lock(); failure = error; chunks.removeAll(); bytes = 0; lock.unlock() }
}
