import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import CallAutomation
import CallCore
import VoiceBridge
import PhoneControl

extension DeskModel: SambhaCallRuntime {
    var sambhaPhoneVisualSnapshot: [String: Any] {
        guard let data = try? JSONEncoder().encode(phoneVisualControl.report),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
    func sambhaPreparePhoneControl(jobID: UUID, number: String) throws {
        try phoneVisualControl.prepare(jobID: jobID, expectedNumber: number)
        sambhaPhoneAttemptID = nil
    }
    func sambhaConfirmPhoneCall() async -> SambhaPhoneReceipt {
        let report = await phoneVisualControl.confirm()
        return .init(callClickPosted: report.confirmationClickPosted, hangupPanelClosed: false, status: report.status)
    }
    func sambhaCancelPhoneControl() { phoneVisualControl.cancel() }
    func sambhaEndPhoneCall() async -> SambhaPhoneReceipt {
        guard let attempt = sambhaPhoneAttemptID, lifecycle.activeAttemptID == attempt else {
            return .init(callClickPosted: phoneVisualControl.report.confirmationClickPosted,
                         hangupPanelClosed: false, status: "The original Phone handoff is no longer the active attempt.")
        }
        if case .requesting = lifecycle.state { lifecycle.reduce(.requestOutcomeUnknown(attempt)) }
        guard lifecycle.reduce(.requestEnd(attempt)) else {
            return .init(callClickPosted: phoneVisualControl.report.confirmationClickPosted,
                         hangupPanelClosed: false, status: "The original Phone handoff cannot accept another end request.")
        }
        let report = await phoneVisualControl.hangup()
        let closed = report.observation == .hangupRequestedPanelClosed && report.hangupClickPosted
        guard lifecycle.activeAttemptID == attempt else {
            return .init(callClickPosted: report.confirmationClickPosted, hangupPanelClosed: false,
                         status: "Phone handoff changed while checking hangup; no retry was made.")
        }
        if closed {
            lifecycle.reduce(.hangupUIPanelClosed(attempt))
            pendingNumber = nil; pendingRecipient = ""
            notice = "Hangup sent · Phone popup closed. Carrier status is not independently available."
        } else {
            lifecycle.reduce(.endOutcomeUnknown(attempt))
            notice = report.status
        }
        return .init(callClickPosted: report.confirmationClickPosted, hangupPanelClosed: closed, status: report.status)
    }
    var sambhaPhoneControlProbeSnapshot: [String: Any] {
        var snapshot: [String: Any] = ["state": phoneControlProbe.state.rawValue,
                                       "status": phoneControlProbe.status,
                                       "phone_status": "unknown"]
        if let json = phoneControlProbe.reportJSON(), let data = json.data(using: .utf8),
           let report = try? JSONSerialization.jsonObject(with: data) {
            snapshot["report"] = report
        }
        return snapshot
    }
    func sambhaStartPhoneControlProbe(expectedNumber: String?) { phoneControlProbe.start(expectedNumber: expectedNumber) }
    func sambhaCancelPhoneControlProbe() { phoneControlProbe.cancel() }
    var sambhaSetupStatus: [String: String] {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "authorized"
        case .notDetermined: microphone = "not_determined"
        case .denied: microphone = "denied"
        default: microphone = "restricted_or_unknown"
        }
        return [
            "microphone": microphone,
            "accessibility": AXIsProcessTrusted() ? "authorized" : "not_authorized",
            "screen_capture": CGPreflightScreenCaptureAccess() ? "authorized" : "not_authorized",
            "signing_mode": Bundle.main.object(forInfoDictionaryKey: "SolarSigningMode") as? String ?? "ad-hoc",
            "api_audio_charges_acknowledged": voiceDataAcknowledged ? "true" : "false",
            "external_route_acknowledged": voiceRoutesAcknowledged ? "true" : "false",
            "api_acknowledgement_saved": voicePersistence.dataAcknowledged ? "true" : "false",
            "route_acknowledgement_saved": voicePersistence.externalRoutingAcknowledged(inputUID: voiceInputUID,
                outputUID: voiceOutputUID, mode: voiceMode) ? "true" : "false",
            "input_uid": voiceInputUID ?? "",
            "output_uid": voiceOutputUID ?? "",
            "phone_control": "guarded_visual_confirmation_and_hangup",
            "unattended_calling": "requires_awake_logged_in_mac_and_supported_phone_popup",
            "end_to_end_automatic_test": "pending"
        ]
    }
    func enableSambhaControl() {
        guard !sambhaEnabled, sambhaEnableTask == nil else { return }
        let token = UUID(); sambhaServerGeneration = token; sambhaControlError = nil
        let server = LocalCommandServer { [weak self] data in
            guard let self, self.sambhaServerGeneration == token else { return Data("{\"ok\":false,\"error\":\"Control instance expired.\"}".utf8) }
            return self.sambhaControl.handle(data)
        }
        sambhaServer = server
        sambhaEnableTask = Task { @MainActor [weak self] in
            do {
                try await server.start()
                guard let self, !Task.isCancelled, self.sambhaServerGeneration == token else { server.stopAndWait(); return }
                self.sambhaControl.enable(); self.sambhaEnabled = true; self.sambhaEnableTask = nil
                UserDefaults.standard.set(true, forKey: "sambha.controlEnabled.v1")
            } catch {
                guard let self, self.sambhaServerGeneration == token else { server.stopAndWait(); return }
                self.sambhaControlError = error.localizedDescription; self.sambhaServer = nil; self.sambhaEnableTask = nil
            }
        }
    }
    func disableSambhaControl(rememberChoice: Bool = true) {
        if rememberChoice { UserDefaults.standard.set(false, forKey: "sambha.controlEnabled.v1") }
        sambhaServerGeneration = UUID(); sambhaEnableTask?.cancel(); sambhaEnableTask = nil
        sambhaControl.disable(); sambhaEnabled = false
        phoneControlProbe.cancel()
        sambhaServer?.stopAndWait(); sambhaServer = nil
    }
    func shutdown() { disableSambhaControl(rememberChoice: false); stopAudioWork() }
    var sambhaBusy: Bool { voice.state.isActive || voiceStartPending || diagnostic.state.isActive || handoffOutstanding || openingWhatsApp || phoneVisualControl.report.busy }
    var sambhaVoiceReady: Bool { voice.state == .listening || voice.state == .speaking }
    var sambhaVoiceFailure: String? { if case .failed(let error) = voice.state { return error }; return voiceStartError }
    func sambhaValidateStart() throws {
        func reject(_ message: String) -> NSError { NSError(domain: "SolarCallDesk.SambhaSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        guard voiceMode == .externalBridge else { throw reject("Choose External bridge in Voice lab.") }
        guard !voiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw reject("Enter the API key in Voice lab; it is never returned through Sambha control.") }
        guard voiceDataAcknowledged, voiceRoutesAcknowledged else { throw reject("Acknowledge API audio data and isolated external routing in Voice lab.") }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined: throw reject("In Voice lab, click Allow microphone access. No test session is needed.")
        case .denied: throw reject("Allow Solar Call Desk in System Settings → Privacy & Security → Microphone, then refresh Microphone access in Voice lab.")
        default: throw reject("Microphone access is restricted or unavailable in macOS. Check Microphone access in Voice lab.")
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mobilephone") != nil else { throw reject("Phone is unavailable on this Mac.") }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw reject("In Connections → Phone automation setup, allow Accessibility and Screen Recording for Solar. These one-time setup permissions enable local verification of Phone’s buttons.")
        }
        try sambhaConfiguration(instructions: voiceInstructions).validate(devices: voice.devices)
    }
    private func sambhaConfiguration(instructions: String) -> VoiceBridgeConfiguration {
        VoiceBridgeConfiguration(inputDeviceID: voiceInput, outputDeviceID: voiceOutput, mode: .externalBridge,
            instructions: instructions, externalRoutingAcknowledged: voiceRoutesAcknowledged,
            inputDeviceUID: voiceInputUID, outputDeviceUID: voiceOutputUID)
    }
    func sambhaInstructions(message: String, recipient: String) -> String { VoiceConversationInstructions.forCallBrief(message, recipient: recipient) }
    func sambhaStartVoice(instructions: String) async throws {
        guard let token = beginVoiceStart(fromSambha: true) else {
            throw NSError(domain: "SolarCallDesk.SambhaSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Competing audio work prevents voice startup."])
        }
        voiceStartError = nil
        defer { finishVoiceStart(token) }
        guard await phoneVisualControl.warmUp() else {
            throw NSError(domain: "SolarCallDesk.SambhaSetup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Phone text recognition could not initialize. No audio or Phone handoff was started."])
        }
        guard !Task.isCancelled, isCurrentVoiceStart(token) else { throw CancellationError() }
        try await voice.start(configuration: sambhaConfiguration(instructions: instructions), apiKey: voiceAPIKey)
    }
    func sambhaStopVoice() { stopAudioWork() }
    func sambhaHandoff(number: PhoneNumber, recipient: String) throws {
        try requestPhoneHandoff(number: number, recipient: recipient, fromSambha: true)
        sambhaPhoneAttemptID = lifecycle.activeAttemptID
    }
    func sambhaConfirmEnded() {
        // A user may report an ended/not-started call before the open callback returns.
        // Record uncertainty first so the existing reducer accepts that actual user report.
        if case .requesting(let attempt) = lifecycle.state { lifecycle.reduce(.requestOutcomeUnknown(attempt)) }
        confirmUserEnded(fromSambha: true)
    }
}

struct SambhaControlCard: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sambha control", systemImage: "terminal").font(.system(size: 16, weight: .semibold))
            Text("Opt in to local commands from Sambha using your Mac account. Prepare a verified number and message, then explicitly start voice and one Phone handoff. Job INPUT and AI-generated transcripts can be returned to Sambha on request. The API key stays in this app.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text("Your Enable/Disable choice is remembered on this Mac. Reopening Solar never resumes a call or starts a voice session.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Text("Solar verifies the recipient number before pressing Call, then requests hangup when Nox finishes or voice stops. The Mac must stay awake and logged in with Phone visible. An unfamiliar popup stops automation. Hangup receipts describe the button press and closed popup; carrier status remains unknown. Voice stops after five minutes.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                StatusPill(text: desk.sambhaEnabled ? "Enabled · local only" : "Disabled", good: desk.sambhaEnabled)
                Spacer()
                if desk.sambhaEnabled || desk.sambhaEnableTask != nil {
                    Button("Disable") { desk.disableSambhaControl() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Enable Sambha control") { desk.enableSambhaControl() }.buttonStyle(PrimaryButtonStyle())
                }
            }
            if desk.sambhaEnabled { Text(LocalCommandServer.defaultPath).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
            if let error = desk.sambhaControlError { Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber).textSelection(.enabled) }
        }.padding(22).cardSurface()
    }
}
