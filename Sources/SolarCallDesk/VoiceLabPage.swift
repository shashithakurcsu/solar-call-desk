import AppKit
import SwiftUI
import VoiceBridge

struct VoiceLabPage: View {
    @EnvironmentObject private var desk: DeskModel
    @ObservedObject var voice: VoiceBridgeCoordinator
    @ObservedObject var diagnostic: VirtualLoopbackDiagnostic

    private var inputDevices: [AudioDevice] { voice.devices.filter { $0.inputChannels > 0 } }
    private var outputDevices: [AudioDevice] { voice.devices.filter { $0.outputChannels > 0 } }
    private var configuration: VoiceBridgeConfiguration {
        VoiceBridgeConfiguration(inputDeviceID: desk.voiceInput, outputDeviceID: desk.voiceOutput,
                                 mode: desk.voiceMode, instructions: desk.voiceInstructions,
                                 externalRoutingAcknowledged: desk.voiceRoutesAcknowledged,
                                 inputDeviceUID: desk.voiceInputUID, outputDeviceUID: desk.voiceOutputUID)
    }
    private var configurationError: String? {
        guard desk.voiceInput != 0, desk.voiceOutput != 0 else { return "Choose an input and an output device." }
        do { try configuration.validate(devices: voice.devices); return nil }
        catch { return error.localizedDescription }
    }
    private var canStart: Bool {
        !voice.state.isActive && !desk.voiceStartPending && !diagnostic.state.isActive && !desk.sambhaControl.hasReservedWork && desk.voiceDataAcknowledged &&
        !desk.voiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && configurationError == nil
    }
    private var stateTitle: String {
        switch voice.state {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .speaking: "Speaking"
        case .failed: "Stopped · error"
        }
    }

    var body: some View {
        PageHeading(eyebrow: "EXPERIMENTAL · SEPARATE API SESSION", title: "Voice lab", subtitle: "A standalone voice session, separate from this Codex conversation.")
            .onAppear { if voice.devices.isEmpty { desk.restoreVoiceSelection() } }

        VirtualBusTestCard(voice: voice, diagnostic: diagnostic)

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Audio route", systemImage: "waveform.path").font(.system(size: 15, weight: .semibold))
                Spacer()
                StatusPill(text: stateTitle, good: voice.state.isActive)
            }
            Picker("Session mode", selection: $desk.voiceMode) {
                Text("Local rehearsal").tag(VoiceBridgeMode.rehearsal)
                Text("External audio bridge (unverified)").tag(VoiceBridgeMode.externalBridge)
            }
            .pickerStyle(.segmented).disabled(voice.state.isActive)
            if desk.voiceMode == .rehearsal {
                Text("Use headphones to reduce feedback. Speak into the selected input; AI speech plays on the selected output. This mode does not connect to WhatsApp or Phone.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Configure two independent, isolated audio buses in your calling app and virtual audio tools before starting:")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Text("Calling app speakers → bus A → Voice lab input\nVoice lab output → bus B → Calling app microphone")
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).lineSpacing(6)
                        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
                    Text("Both selections must be virtual devices with different IDs. That check cannot prove isolation or a working Phone/WhatsApp route; mirrored devices can create feedback.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Text("Start this session and wait for Listening before calling in Phone. Keep the session running throughout the call; hang up in Phone separately.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    Toggle("I configured independent, isolated buses; Phone/WhatsApp routing is still unverified.", isOn: $desk.voiceRoutesAcknowledged)
                        .toggleStyle(.checkbox).font(.system(size: 11)).disabled(voice.state.isActive)
                    Text("Remembered for this exact input, output, and external mode. Uncheck to revoke; a different route requires its own acknowledgement.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                devicePicker("Voice lab input", selection: $desk.voiceInput, devices: inputDevices)
                devicePicker("Voice lab output", selection: $desk.voiceOutput, devices: outputDevices)
            }.disabled(voice.state.isActive)
            HStack {
                Text("Device checks do not record audio.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button { desk.restoreVoiceSelection() } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(voice.state.isActive)
            }
            if !voice.state.isActive, let error = configurationError {
                Label(error, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.padding(22).cardSurface()

        MicrophoneAccessCard(voice: voice, diagnostic: diagnostic)
        if let notice = desk.voicePreferenceNotice {
            Text(notice).font(.system(size: 11)).foregroundStyle(Palette.amber).textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 15) {
            Label("Session setup", systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("OpenAI API key").font(.system(size: 11, weight: .medium))
                    Spacer()
                    if !desk.voiceAPIKey.isEmpty, !voice.state.isActive {
                        Button("Clear key") { desk.voiceAPIKey = "" }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.teal)
                    }
                }
                SecureField("Enter your own API key", text: $desk.voiceAPIKey)
                    .textFieldStyle(.plain).inputSurface().disabled(voice.state.isActive)
                    .accessibilityLabel("OpenAI API key")
                Text("A separate API session billed to this key. Audio devices, session mode, and your acknowledgement choices are remembered. Sessions start only when requested.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                Text("Save this key in this Mac’s Keychain and load it when Solar opens. macOS may ask you to allow access, especially after updates. Saving is optional; typing does not update a saved key.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                HStack {
                    Button(desk.voicePersistence.keyOptIn ? "Update saved key" : "Save key in Keychain") {
                        desk.saveVoiceKeyExplicitly()
                    }.buttonStyle(SecondaryButtonStyle()).disabled(desk.voiceAPIKey.isEmpty || desk.voicePersistence.credentialBusy)
                    if desk.voicePersistence.keyOptIn {
                        Button("Load saved key") { desk.loadSavedVoiceKey() }.buttonStyle(SecondaryButtonStyle()).disabled(desk.voicePersistence.credentialBusy)
                    }
                    Button("Forget saved key") { desk.forgetSavedVoiceKey() }.buttonStyle(SecondaryButtonStyle()).disabled(desk.voicePersistence.credentialBusy)
                }.disabled(voice.state.isActive || desk.voiceStartPending)
                if let notice = desk.voicePersistence.credentialNotice {
                    Text(notice).font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Conversation instructions").font(.system(size: 11, weight: .medium))
                    Spacer()
                    if !desk.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Use call desk brief") {
                            desk.voiceInstructions = VoiceConversationInstructions.forCallBrief(desk.brief, recipient: desk.recipient)
                        }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.teal)
                            .disabled(voice.state.isActive)
                    }
                }
                TextEditor(text: $desk.voiceInstructions).font(.system(size: 12))
                    .scrollContentBackground(.hidden).frame(height: 65)
                    .padding(6).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .disabled(voice.state.isActive).accessibilityLabel("Voice session instructions")
                Text("Sent to OpenAI when you start. Model: gpt-realtime-2.1 · Voice: marin.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Toggle("I agree to send selected input audio to OpenAI and incur API usage charges.", isOn: $desk.voiceDataAcknowledged)
                .toggleStyle(.checkbox).font(.system(size: 11)).disabled(voice.state.isActive)
            Text("Remembered on this Mac until you uncheck it. This consent is separate from saving an API key.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            HStack(spacing: 13) {
                Text("Start may request microphone permission. The lab does not place or end calls.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if voice.state.isActive || desk.voiceStartPending {
                    Button { desk.stopAudioWork() } label: { Label("Stop session", systemImage: "stop.fill") }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("stop-voice-session")
                } else {
                    Button { startSession() } label: { Label("Start session", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!canStart)
                        .accessibilityIdentifier("start-voice-session")
                }
            }
            if let error = desk.voiceStartError ?? voice.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }.padding(22).cardSurface()

        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Session transcript").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("IN MEMORY").font(.system(size: 9, weight: .medium)).tracking(1.1).foregroundStyle(Palette.muted)
            }
            Text("AI text is generated speech; interrupted or externally routed audio may not have been heard.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            if voice.transcripts.isEmpty {
                Text("No transcript yet. Only actual input and AI transcripts from a started session appear here.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            } else {
                ForEach(voice.transcripts) { transcript in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transcript.speaker == .assistant ? "AI" : "INPUT")
                            .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Palette.teal)
                        Text(transcript.text).font(.system(size: 12)).textSelection(.enabled)
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }.padding(22).cardSurface()

        HStack(spacing: 18) {
            Link("OpenAI voice documentation ↗", destination: URL(string: "https://developers.openai.com/api/docs/guides/realtime-conversations")!)
            Link("Virtual audio routing reference ↗", destination: URL(string: "https://github.com/ExistentialAudio/BlackHole")!)
        }.font(.system(size: 11, weight: .medium)).tint(Palette.teal)
        PrivacyNote()
    }

    private func devicePicker(_ title: String, selection: Binding<UInt32>, devices: [AudioDevice]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .medium))
            Picker(title, selection: selection) {
                Text("Choose a device").tag(UInt32(0))
                ForEach(devices) { device in
                    Text(device.name + (device.isVirtual ? " · virtual" : "")).tag(device.id)
                }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startSession() {
        guard canStart, let token = desk.beginVoiceStart() else { return }
        desk.voiceStartError = nil
        let config = configuration
        let key = desk.voiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        desk.voiceStartTask = Task { @MainActor in
            defer { desk.finishVoiceStart(token) }
            guard !Task.isCancelled, desk.isCurrentVoiceStart(token), !diagnostic.state.isActive else { return }
            do { try await voice.start(configuration: config, apiKey: key) }
            catch {
                guard !Task.isCancelled, desk.isCurrentVoiceStart(token) else { return }
                desk.voiceStartError = error.localizedDescription
            }
        }
    }
}

struct HeaderVoiceControl: View {
    @EnvironmentObject private var desk: DeskModel
    @ObservedObject var voice: VoiceBridgeCoordinator
    @ObservedObject var diagnostic: VirtualLoopbackDiagnostic
    var body: some View {
        if voice.state.isActive || desk.voiceStartPending || diagnostic.state.isActive {
            Button { desk.stopAudioWork() } label: {
                Label("Stop audio", systemImage: "stop.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.teal)
            }.buttonStyle(.plain).help("Stops the local bus test and Voice lab audio/API connection. Does not hang up a call.")
                .accessibilityIdentifier("persistent-stop-voice-session")
        } else {
            Label("User-controlled", systemImage: "lock.shield").font(.system(size: 11))
        }
    }
}
