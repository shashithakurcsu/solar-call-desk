import SwiftUI
import VoiceBridge

struct VirtualBusTestCard: View {
    @EnvironmentObject private var desk: DeskModel
    @ObservedObject var voice: VoiceBridgeCoordinator
    @ObservedObject var diagnostic: VirtualLoopbackDiagnostic

    private var twoDevices: [AudioDevice] {
        voice.devices.filter { $0.isVirtual && $0.uid == "BlackHole2ch_UID" }
    }
    private var sixteenDevices: [AudioDevice] {
        voice.devices.filter { $0.isVirtual && $0.uid == "BlackHole16ch_UID" }
    }
    private var canStart: Bool {
        !diagnostic.state.isActive && !voice.state.isActive && !desk.voiceStartPending && !desk.sambhaControl.hasReservedWork &&
        !desk.handoffOutstanding && desk.probeNoCallsAcknowledged &&
        desk.probeTwoSelection != nil && desk.probeSixteenSelection != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Local virtual-bus test", systemImage: "waveform.path")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(diagnostic.state.isActive ? "TESTING" : "NO NETWORK · NO API KEY")
                    .font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(Palette.muted)
            }
            HStack {
                Text("Device discovery is read-only. Mirror devices are excluded.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button { voice.refreshDevices() } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(diagnostic.state.isActive || voice.state.isActive || desk.voiceStartPending)
            }
            Text("Test synthetic tones on averaged channels 1–2 of the exact primary BlackHole 2ch and 16ch devices. This one-time test checks signal return and separation on that first pair.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Primary BlackHole 2ch").font(.system(size: 11, weight: .medium))
                    Picker("Primary BlackHole 2ch", selection: $desk.probeTwoID) {
                        Text("Choose a device").tag(UInt32(0))
                        ForEach(twoDevices) { device in Text(device.name).tag(device.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Primary BlackHole 16ch").font(.system(size: 11, weight: .medium))
                    Picker("Primary BlackHole 16ch", selection: $desk.probeSixteenID) {
                        Text("Choose a device").tag(UInt32(0))
                        ForEach(sixteenDevices) { device in Text(device.name).tag(device.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(diagnostic.state.isActive || voice.state.isActive || desk.voiceStartPending)
            .onChange(of: desk.probeTwoID) { _, selected in
                desk.probeTwoSelection = twoDevices.first(where: { $0.id == selected })
                desk.probeNoCallsAcknowledged = false
            }
            .onChange(of: desk.probeSixteenID) { _, selected in
                desk.probeSixteenSelection = sixteenDevices.first(where: { $0.id == selected })
                desk.probeNoCallsAcknowledged = false
            }
            if twoDevices.isEmpty || sixteenDevices.isEmpty {
                Text("Both primary devices must be installed and loaded. Missing: " +
                     [twoDevices.isEmpty ? "BlackHole 2ch" : nil, sixteenDevices.isEmpty ? "BlackHole 16ch" : nil]
                    .compactMap { $0 }.joined(separator: ", ") + ". Refresh devices after installation or restart.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Toggle("I checked that no calls or recordings are active on these devices.", isOn: $desk.probeNoCallsAcknowledged)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .disabled(diagnostic.state.isActive || voice.state.isActive || desk.voiceStartPending)
            HStack(spacing: 12) {
                Text("Start may request microphone permission. No audio is uploaded. Phone audio is not yet tested.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if diagnostic.state.isActive {
                    Button { desk.stopAudioWork() } label: { Label("Stop test", systemImage: "stop.fill") }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("stop-virtual-bus-test")
                } else {
                    Button { startTest() } label: { Label("Start one-time test", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!canStart)
                        .accessibilityIdentifier("start-virtual-bus-test")
                }
            }
            if desk.handoffOutstanding {
                Text("Resolve the previous Phone handoff in the calling app before testing.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else if voice.state.isActive || desk.voiceStartPending {
                Text("Stop the API voice session before testing virtual buses.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if let error = diagnostic.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let report = diagnostic.result {
                Divider()
                Text(report.passed ? "Virtual buses passed this test; Phone/WhatsApp unverified." :
                        "Virtual buses did not pass this test; Phone/WhatsApp unverified.")
                    .font(.system(size: 12, weight: .semibold))
                Text("This result applies only to the tested virtual devices at that moment. It does not verify a calling app's audio, enable AI calls, or confirm that anyone heard audio.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(report.scopeDescription).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let started = desk.probeStartedAt {
                    Text("Test initiated: \(started.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Text("Tested \(report.twoChannelDevice.name) · ID \(report.twoChannelDevice.id) · UID \(report.twoChannelDevice.uid)")
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Text("Input \(report.twoChannelInputSampleRate.formatted()) Hz · output \(report.twoChannelOutputSampleRate.formatted()) Hz · capture \(report.twoChannel.captureSampleRate.formatted()) Hz · \(report.twoChannel.analyzedFrames) analyzed frames · \((Double(report.twoChannel.capturedFrames) / report.twoChannel.captureSampleRate).formatted(.number.precision(.fractionLength(2)))) s captured")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
                Text("2ch \(report.twoChannel.passed ? "pass" : "fail") · RMS \(Double(report.twoChannel.ownRMS).formatted(.number.precision(.fractionLength(4)))) · other-bus RMS \(Double(report.twoChannel.otherRMS).formatted(.number.precision(.fractionLength(4)))) · correlation \(Double(report.twoChannel.correlation).formatted(.number.precision(.fractionLength(3)))) · gain \(Double(report.twoChannel.gain).formatted(.number.precision(.fractionLength(3)))) · leakage \(Double(report.twoChannel.leakageRatio).formatted(.number.precision(.fractionLength(4))))")
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Text("Tested \(report.sixteenChannelDevice.name) · ID \(report.sixteenChannelDevice.id) · UID \(report.sixteenChannelDevice.uid)")
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Text("Input \(report.sixteenChannelInputSampleRate.formatted()) Hz · output \(report.sixteenChannelOutputSampleRate.formatted()) Hz · capture \(report.sixteenChannel.captureSampleRate.formatted()) Hz · \(report.sixteenChannel.analyzedFrames) analyzed frames · \((Double(report.sixteenChannel.capturedFrames) / report.sixteenChannel.captureSampleRate).formatted(.number.precision(.fractionLength(2)))) s captured")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).textSelection(.enabled)
                Text("16ch \(report.sixteenChannel.passed ? "pass" : "fail") · RMS \(Double(report.sixteenChannel.ownRMS).formatted(.number.precision(.fractionLength(4)))) · other-bus RMS \(Double(report.sixteenChannel.otherRMS).formatted(.number.precision(.fractionLength(4)))) · correlation \(Double(report.sixteenChannel.correlation).formatted(.number.precision(.fractionLength(3)))) · gain \(Double(report.sixteenChannel.gain).formatted(.number.precision(.fractionLength(3)))) · leakage \(Double(report.sixteenChannel.leakageRatio).formatted(.number.precision(.fractionLength(4))))")
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
        }.padding(22).cardSurface()
    }

    private func startTest() {
        guard canStart, !voice.state.isActive, !desk.voiceStartPending, !desk.sambhaControl.hasReservedWork, !desk.handoffOutstanding,
              let two = desk.probeTwoSelection, let sixteen = desk.probeSixteenSelection else { return }
        desk.probeStartedAt = Date()
        diagnostic.start(configuration: VirtualLoopbackConfiguration(
            twoChannelDevice: two, sixteenChannelDevice: sixteen,
            noActiveCallsAcknowledged: desk.probeNoCallsAcknowledged))
        desk.probeNoCallsAcknowledged = false
    }
}
