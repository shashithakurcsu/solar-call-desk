@preconcurrency import AVFoundation
import Combine
import Foundation

public enum VoiceBridgeEvent: Sendable {
    case state(VoiceBridgeState), transcript(VoiceTranscript), interrupted, error(String), conversationCompleted
}

/// Single-user experimental API client. Start must be called only by the user's explicit app action.
/// This is a separately billed OpenAI API session; it cannot access the current Codex conversation.
@MainActor public final class VoiceBridgeCoordinator: ObservableObject {
    @Published public private(set) var state: VoiceBridgeState = .idle
    @Published public private(set) var devices: [AudioDevice] = []
    @Published public private(set) var transcripts: [VoiceTranscript] = []
    @Published public private(set) var lastError: String?
    public var onEvent: ((VoiceBridgeEvent) -> Void)?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var audio: (any VoiceAudioEndpoint)?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = UUID()
    private var pendingConfig: VoiceBridgeConfiguration?
    private var outgoing = VoiceOutgoingBuffer()
    private var sendMessage: (@MainActor (String) async throws -> Void)?
    private var responseAudio = ResponseAudioBuffer()
    private var pumpTick = 0
    private var completedResponseIDs: [String] = []
    private var updateSent = false
    private var activeResponseID: String?
    private var interruptedIDs: [String] = []
    private var farewellToken: String?
    private var farewellResponseID: String?
    private var pendingFarewellCallID: String?
    private var farewellDone = false
    private var farewellTask: Task<Void, Never>?
    private var farewellDrainTask: Task<Void, Never>?
    private var abandonedFarewellTokens: [String] = []
    private var callerSpeaking = false
    private let conversationFinishDelay: Duration
    private let networkDelegate = OfficialEndpointOnly()
    private var lastShutdownError: String?

    public init() { conversationFinishDelay = .milliseconds(750) }
    init(conversationFinishDelay: Duration) { self.conversationFinishDelay = conversationFinishDelay }
    /// Read-only enumeration; does not create engines, access microphones, or change defaults.
    public func refreshDevices() {
        do { devices = try AudioDeviceCatalog.devices() }
        catch { lastError = error.localizedDescription }
    }

    public func start(configuration: VoiceBridgeConfiguration, apiKey: String) async throws {
        guard !state.isActive else { throw VoiceBridgeError.configuration("Stop the current voice session first.") }
        try NativeExternalAudio.requireSafeShutdown()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count < 4096, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw VoiceBridgeError.configuration("Enter a valid OpenAI API key.")
        }
        let freshDevices = try AudioDeviceCatalog.devices()
        try configuration.validate(devices: freshDevices)
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String else {
            throw VoiceBridgeError.configuration("This app bundle is missing its microphone permission description.")
        }
        stop()
        if let lastShutdownError { throw VoiceBridgeError.route(lastShutdownError) }
        let permissionToken = generation
        let granted = try await MicrophoneAuthorization.authorize(status: AVCaptureDevice.authorizationStatus(for: .audio)) {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard generation == permissionToken, !Task.isCancelled else { throw CancellationError() }
        guard granted else { throw VoiceBridgeError.microphoneDenied }
        try configuration.validate(devices: AudioDeviceCatalog.devices())
        devices = freshDevices; transcripts.removeAll(); lastError = nil
        pendingConfig = configuration; let token = generation
        var request = URLRequest(url: RealtimeProtocol.endpoint(model: configuration.model))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
        settings.httpShouldSetCookies = false; settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: settings, delegate: networkDelegate, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        self.socket = socket
        sendMessage = { text in try await socket.send(.string(text)) }
        changeState(.connecting)
        socket.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, self.generation == token else { return }
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let data):
                        guard let decoded = String(data: data, encoding: .utf8) else {
                            throw VoiceBridgeError.protocolViolation("Non-JSON WebSocket event.")
                        }
                        text = decoded
                    @unknown default: throw VoiceBridgeError.protocolViolation("Unsupported WebSocket message.")
                    }
                    try self.processEvent(RealtimeProtocol.parse(text))
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.fail(error is VoiceBridgeError ? error.localizedDescription : "Realtime connection ended or authentication failed. Start again to retry.")
                    return
                }
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.generation == token, self.state == .connecting else { return }
            self.fail("Realtime configuration timed out. No audio session was started.")
        }
    }

    public func stop() {
        generation = UUID()
        receiveTask?.cancel(); sendTask?.cancel(); pumpTask?.cancel(); setupTask?.cancel(); timeoutTask?.cancel(); farewellTask?.cancel(); farewellDrainTask?.cancel()
        receiveTask = nil; sendTask = nil; pumpTask = nil; setupTask = nil; timeoutTask = nil
        lastShutdownError = audio?.stop(); audio = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        outgoing.clear(); sendMessage = nil; responseAudio.clear(); pumpTick = 0; completedResponseIDs.removeAll(); pendingConfig = nil; updateSent = false
        activeResponseID = nil; interruptedIDs.removeAll()
        farewellTask = nil; farewellToken = nil; farewellResponseID = nil; pendingFarewellCallID = nil; farewellDone = false
        farewellDrainTask = nil; abandonedFarewellTokens.removeAll(); callerSpeaking = false
        changeState(.idle)
        if let lastShutdownError { lastError = lastShutdownError; onEvent?(.error(lastShutdownError)) }
    }

    /// Clear locally displayed transcripts; audio is never written to disk.
    public func clearTranscripts() { transcripts.removeAll() }

    private func changeState(_ value: VoiceBridgeState) { state = value; onEvent?(.state(value)) }
    private func fail(_ message: String) {
        stop()
        let finalMessage = lastShutdownError.map { "\(message) Cleanup: \($0)" } ?? message
        lastError = finalMessage; changeState(.failed(finalMessage)); onEvent?(.error(finalMessage))
    }

    private func enqueue(_ text: String, setup: Bool = false) throws {
        guard sendMessage != nil else { throw VoiceBridgeError.protocolViolation("Session is closed.") }
        if setup { try outgoing.appendSetup(text) } else { try outgoing.appendControl(text) }
        beginSending()
    }
    private func beginSending() {
        guard sendTask == nil else { return }
        let token = generation
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.generation == token, let value = try self.outgoing.next() {
                    guard let send = self.sendMessage else { return }
                    try await send(value)
                    guard self.generation == token else { return }
                    self.outgoing.sent()
                }
                if self.generation == token { self.sendTask = nil }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(error is VoiceBridgeError ? error.localizedDescription : "Realtime send failed. Audio session stopped; reconnect requires Start.")
            }
        }
    }

    // Production startup and offline tests attach the same runtime. No devices or network
    // are created here; the explicit Start path remains solely responsible for authorization.
    func attachConfiguredAudio(_ audio: any VoiceAudioEndpoint,
                               send: @escaping @MainActor (String) async throws -> Void,
                               runPump: Bool = true) {
        self.audio = audio; sendMessage = send
        let token = generation
        audio.onDrained = { [weak self] in
            guard let self, self.generation == token else { return }
            if self.responseAudio.stagedFrames == 0 && self.activeResponseID == nil && self.state == .speaking {
                self.changeState(.listening)
            }
            do { try self.scheduleFarewellIfDrained() }
            catch { self.fail(error.localizedDescription); return }
            self.finishVoiceIfDrained()
        }
        pendingConfig = nil; timeoutTask?.cancel(); timeoutTask = nil
        changeState(.listening)
        if runPump { beginPump(token: token) }
    }
    func processEvent(_ event: [String: Any]) throws { try handle(event, token: generation) }

    private func handle(_ event: [String: Any], token: UUID) throws {
        switch event["type"] as? String {
        case "session.created":
            guard !updateSent, let config = pendingConfig else { return }
            updateSent = true
            try enqueue(RealtimeProtocol.sessionUpdate(config), setup: true)
        case "session.updated":
            guard updateSent, audio == nil, setupTask == nil, let config = pendingConfig else { return }
            try RealtimeProtocol.validateAcknowledgedAudio(event)
            timeoutTask?.cancel(); timeoutTask = nil
            setupTask = Task { [weak self] in
                guard let self, self.generation == token, !Task.isCancelled else { return }
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { self.fail(VoiceBridgeError.microphoneDenied.localizedDescription); return }
                do {
                    try config.validate(devices: AudioDeviceCatalog.devices())
                    let audio = SelectedDeviceAudio()
                    self.audio = audio // owns cleanup even if setup fails part-way
                    try audio.start(config) { [weak self] message in
                        guard let self, self.generation == token else { return }
                        self.fail(message)
                    }
                    guard let send = self.sendMessage else { throw VoiceBridgeError.protocolViolation("Session is closed.") }
                    self.attachConfiguredAudio(audio, send: send)
                } catch { self.fail(error.localizedDescription) }
            }
        case "response.created":
            guard audio != nil, let response = event["response"] as? [String: Any], let id = response["id"] as? String else { return }
            guard !interruptedIDs.contains(id), !completedResponseIDs.contains(id) else { return }
            let metadata = response["metadata"] as? [String: Any]
            if let oldMarker = metadata?["solar_farewell"] as? String, abandonedFarewellTokens.contains(oldMarker) {
                try enqueue(RealtimeProtocol.json(["type": "response.cancel", "response_id": id]))
                return
            }
            if let farewellToken {
                guard farewellResponseID == nil, metadata?["solar_farewell"] as? String == farewellToken else {
                    try enqueue(RealtimeProtocol.json(["type": "response.cancel", "response_id": id]))
                    return
                }
                farewellResponseID = id
            }
            activeResponseID = id
        case "response.output_audio.delta":
            guard let audio else { throw VoiceBridgeError.protocolViolation("Audio received before configuration was accepted.") }
            guard let response = event["response_id"] as? String, let item = event["item_id"] as? String,
                  let index = event["content_index"] as? Int, index >= 0 else {
                throw VoiceBridgeError.protocolViolation("Response audio identifiers are missing.")
            }
            if interruptedIDs.contains(response) || completedResponseIDs.contains(response) { return }
            guard response == activeResponseID || response == responseAudio.responseID else { return }
            let data = try RealtimeProtocol.audio(event)
            guard try responseAudio.append(data, response: response, item: item, index: index,
                                           hardwareFrames: audio.queuedPlaybackFrames) else {
                try cancelOutput(notice: "Response audio exceeded the 60-second buffer bound (staged=\(responseAudio.stagedFrames)frames, hardware=\(audio.queuedPlaybackFrames)frames, incoming=\(data.count / 2)frames, limit=1440000frames). This response was canceled; listening continues.")
                return
            }
            try feedPlayback()
            changeState(.speaking)
        case "input_audio_buffer.speech_started":
            callerSpeaking = true
            try abandonFarewell()
            try cancelOutput(notice: nil)
        case "input_audio_buffer.speech_stopped":
            callerSpeaking = false
        case "response.done":
            if let response = event["response"] as? [String: Any] {
                if let id = response["id"] as? String {
                    let wasCurrent = id == activeResponseID || id == responseAudio.responseID
                    let firstCompletion = !completedResponseIDs.contains(id) && !interruptedIDs.contains(id)
                    if id == farewellResponseID {
                        guard response["status"] as? String == "completed" else {
                            throw VoiceBridgeError.protocolViolation("Closing speech was interrupted. Voice stopped; check Phone separately.")
                        }
                        farewellDone = true
                    }
                    responseAudio.markDone(id)
                    completedResponseIDs.append(id); if completedResponseIDs.count > 32 { completedResponseIDs.removeFirst() }
                    if id == activeResponseID { activeResponseID = nil }
                    try feedPlayback()
                    if wasCurrent, firstCompletion, !callerSpeaking, farewellToken == nil, let callID = try RealtimeProtocol.finishCallID(response) {
                        try beginFarewell(callID: callID)
                    }
                    finishVoiceIfDrained()
                }
                if response["status"] as? String == "failed" {
                    throw VoiceBridgeError.protocolViolation("Realtime response failed. Review API model access and billing before retrying.")
                }
            }
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"] as? String { addTranscript(.caller, text: text) }
        case "response.output_audio_transcript.done":
            if let id = event["response_id"] as? String, interruptedIDs.contains(id) { return }
            if let text = event["transcript"] as? String { addTranscript(.assistant, text: text) }
        case "error", "conversation.item.input_audio_transcription.failed":
            // Never expose arbitrary server text: it can echo request data. Only a short known character code is displayed.
            let details = event["error"] as? [String: Any]
            let code = details?["code"] as? String ?? "unknown"
            if code == "response_cancel_not_active" { return }
            let safeCode = code.count <= 64 && code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? code : "unknown"
            throw VoiceBridgeError.protocolViolation("Realtime API error (\(safeCode)). Session stopped. Check account access, key and billing.")
        default: break
        }
    }

    private func cancelOutput(notice: String?) throws {
        // response.done can arrive before local playback ends. Staging also owns the
        // current item before its first consolidated hardware chunk has been scheduled.
        let stagedResponse = responseAudio.responseID, stagedItem = responseAudio.itemID
        let stagedIndex = responseAudio.contentIndex, active = activeResponseID
        let hadHardwareSpeech = (audio?.queuedPlaybackFrames ?? 0) > 0
        let stagedNeedsTruncation = stagedItem != nil && (responseAudio.stagedFrames > 0 || hadHardwareSpeech || !responseAudio.done)
        for response in [stagedNeedsTruncation ? stagedResponse : nil, active].compactMap({ $0 }) where !interruptedIDs.contains(response) {
            interruptedIDs.append(response); if interruptedIDs.count > 32 { interruptedIDs.removeFirst() }
        }
        if let active { try enqueue(RealtimeProtocol.json(["type": "response.cancel", "response_id": active])) }
        activeResponseID = nil; responseAudio.clear()
        let played = audio?.interrupt()
        if stagedNeedsTruncation, let stagedItem {
            let frames = played?.item == stagedItem && played?.index == stagedIndex ? played!.frames : 0
            try enqueue(RealtimeProtocol.truncate(itemID: stagedItem, contentIndex: stagedIndex, playedFrames: frames))
            onEvent?(.interrupted)
        } else if hadHardwareSpeech, let played {
            try enqueue(RealtimeProtocol.truncate(itemID: played.item, contentIndex: played.index, playedFrames: played.frames))
            onEvent?(.interrupted)
        }
        if audio != nil { changeState(.listening) }
        if let notice { lastError = notice; onEvent?(.error(notice)) }
    }
    private func feedPlayback() throws {
        guard let audio, let item = responseAudio.itemID else { return }
        while responseAudio.stagedFrames > 0 {
            let available = ResponseAudioBuffer.hardwareLead - audio.queuedPlaybackFrames
            guard available > 0 else { break }
            let frames = min(ResponseAudioBuffer.chunkFrames, Int(available), Int(responseAudio.stagedFrames))
            // Keep fragments consolidated while the response is still arriving. A done
            // event flushes the final short tail without inventing or dropping samples.
            if frames < ResponseAudioBuffer.chunkFrames && !responseAudio.done { break }
            let data = responseAudio.take(frames: frames)
            try audio.play(data, item: item, index: responseAudio.contentIndex)
        }
        if responseAudio.done && responseAudio.stagedFrames == 0 && audio.queuedPlaybackFrames == 0 {
            responseAudio.clear()
            if activeResponseID == nil && state == .speaking { changeState(.listening) }
        }
    }
    private func beginFarewell(callID: String) throws {
        guard audio != nil, farewellToken == nil else { return }
        let marker = UUID().uuidString, token = generation
        farewellToken = marker
        pendingFarewellCallID = callID
        try scheduleFarewellIfDrained()
        farewellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.generation == token, self.farewellToken == marker else { return }
            self.fail("Closing speech did not finish in time. Voice stopped; check Phone separately.")
        }
    }
    private func scheduleFarewellIfDrained() throws {
        guard let marker = farewellToken, let callID = pendingFarewellCallID, let audio,
              responseAudio.stagedFrames == 0, audio.queuedPlaybackFrames == 0, activeResponseID == nil else { return }
        pendingFarewellCallID = nil
        try enqueue(RealtimeProtocol.finishToolResult(callID: callID))
        try enqueue(RealtimeProtocol.farewellResponse(token: marker))
    }
    private func finishVoiceIfDrained() {
        guard farewellDone, !callerSpeaking, farewellDrainTask == nil, let marker = farewellToken, let audio,
              responseAudio.stagedFrames == 0, audio.queuedPlaybackFrames == 0, activeResponseID == nil else { return }
        let token = generation, delay = conversationFinishDelay
        farewellDrainTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == token, self.farewellToken == marker else { return }
            self.farewellDrainTask = nil
            guard self.farewellDone, !self.callerSpeaking, let audio = self.audio,
                  self.responseAudio.stagedFrames == 0, audio.queuedPlaybackFrames == 0, self.activeResponseID == nil else { return }
            self.stop()
            self.onEvent?(.conversationCompleted)
        }
    }
    private func abandonFarewell() throws {
        guard let marker = farewellToken else { return }
        if let callID = pendingFarewellCallID {
            try enqueue(RealtimeProtocol.finishToolResult(callID: callID, continuing: true))
        }
        abandonedFarewellTokens.append(marker)
        if abandonedFarewellTokens.count > 32 { abandonedFarewellTokens.removeFirst() }
        farewellTask?.cancel(); farewellDrainTask?.cancel()
        farewellTask = nil; farewellDrainTask = nil; farewellToken = nil; pendingFarewellCallID = nil
        farewellResponseID = nil; farewellDone = false
    }
    func pumpOnce() throws {
        guard let audio else { return }
        pumpTick += 1
        if pumpTick % 5 == 0 { try audio.verifyDevices(stage: "voice route verification", requireRunning: nil) }
        for chunk in try audio.capture.drain() { try outgoing.appendPCM(chunk) }
        if pumpTick % 2 == 0 { outgoing.flushInputTail() }
        beginSending()
        try feedPlayback()
        try scheduleFarewellIfDrained()
        finishVoiceIfDrained()
    }
    func flowDiagnostics() -> VoiceFlowDiagnostics {
        VoiceFlowDiagnostics(outgoingReservedBytes: outgoing.reservedBytes, outgoingReservedMessages: outgoing.reservedMessages,
            inFlightBytes: outgoing.inFlightBytes, pendingInputBytes: outgoing.pendingPCMBytes,
            stagedOutputFrames: responseAudio.stagedFrames, hardwareOutputFrames: audio?.queuedPlaybackFrames ?? 0)
    }

    private func beginPump(token: UUID) {
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self, self.generation == token, self.audio != nil else { return }
                do { try self.pumpOnce() }
                catch { self.fail(error.localizedDescription); return }
            }
        }
    }
    private func addTranscript(_ speaker: VoiceTranscript.Speaker, text: String) {
        let transcript = VoiceTranscript(speaker: speaker, text: String(text.prefix(10_000)))
        transcripts.append(transcript)
        if transcripts.count > 100 { transcripts.removeFirst() }
        onEvent?(.transcript(transcript))
    }
}

/// Prevent credential-bearing requests from following redirects to any endpoint.
private final class OfficialEndpointOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
