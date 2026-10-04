import AppKit
import Combine
import SwiftUI
import CallCore
import VoiceBridge
import CallAutomation
import PhoneControl

@MainActor
final class DeskAppDelegate: NSObject, NSApplicationDelegate {
    var desk: DeskModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { desk?.shutdown() }
}

@main
struct SolarCallDeskApp: App {
    @NSApplicationDelegateAdaptor(DeskAppDelegate.self) private var appDelegate
    @StateObject private var desk = DeskModel()

    var body: some Scene {
        WindowGroup("Solar Call Desk") {
            DeskView()
                .environmentObject(desk)
                .frame(minWidth: 850, minHeight: 620)
                .preferredColorScheme(.light)
                .onAppear { appDelegate.desk = desk }
        }
        .defaultSize(width: 1040, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Solar Call Desk") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Solar Call Desk",
                        .applicationVersion: "0.1 · Local prototype",
                        .credits: NSAttributedString(string: "A call preparation desk with an experimental, separate API Voice lab.\nPhone/WhatsApp audio routing is unverified.\nVoice lab sends selected input audio to OpenAI only after you start it.\nNo recording to disk or telemetry. Audio devices and session mode are saved locally; API keys stay in memory unless explicitly saved in this Mac’s Keychain.")
                    ])
                }
            }
        }
    }
}

enum DeskPage: String, CaseIterable, Identifiable {
    case desk = "Call desk"
    case connections = "Connections"
    case voiceLab = "Voice lab"
    case activity = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .desk: "phone.bubble"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .voiceLab: "waveform"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

enum DeskRoute: String, CaseIterable, Identifiable {
    case whatsapp = "WhatsApp"
    case phone = "Phone"
    var id: String { rawValue }
    var symbol: String { self == .whatsapp ? "message.fill" : "phone.fill" }
}

struct DeskActivity: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let detail: String
    let symbol: String
}

@MainActor
final class DeskModel: ObservableObject {
    let voice = VoiceBridgeCoordinator()
    let diagnostic = VirtualLoopbackDiagnostic()
    private var diagnosticObservation: AnyCancellable?
    var voiceStartTask: Task<Void, Never>?
    private var voiceStartGeneration = UUID()
    @Published var voiceStartPending = false
    @Published var probeTwoID: UInt32 = 0
    @Published var probeSixteenID: UInt32 = 0
    @Published var probeTwoSelection: AudioDevice?
    @Published var probeSixteenSelection: AudioDevice?
    @Published var probeNoCallsAcknowledged = false
    @Published var probeStartedAt: Date?
    @Published var sambhaEnabled = false
    @Published var sambhaControlError: String?
    @Published var sambhaEnableTask: Task<Void, Never>?
    var sambhaServer: LocalCommandServer?
    var sambhaServerGeneration = UUID()
    lazy var sambhaControl = SambhaJobController(runtime: self)
    let phoneControlProbe = PhoneControlProbe()
    let phoneVisualControl = PhoneVisualController()
    var sambhaPhoneAttemptID: UUID?
    let voicePersistence = VoiceSettingsPersistence(preferences: UserDefaultsVoicePreferences(), credentials: LocalKeychainCredentialStore())
    private var voicePersistenceObservation: AnyCancellable?
    private var restoringVoicePreferences = true
    private var restoringVoiceRouteAcknowledgement = false
    private var voiceKeyFieldGeneration = UUID()
    private var credentialTask: Task<Void, Never>?
    @Published var voicePreferenceNotice: String?
    @Published var voiceAPIKey = "" { didSet { voiceKeyFieldGeneration = UUID() } }
    @Published var voiceInput: UInt32 = 0 {
        didSet {
            guard !restoringVoicePreferences else { return }
            voiceInputUID = voice.devices.first(where: { $0.id == voiceInput })?.uid
        }
    }
    @Published var voiceOutput: UInt32 = 0 {
        didSet {
            guard !restoringVoicePreferences else { return }
            voiceOutputUID = voice.devices.first(where: { $0.id == voiceOutput })?.uid
        }
    }
    @Published var voiceInputUID: String? { didSet { saveVoiceSelection() } }
    @Published var voiceOutputUID: String? { didSet { saveVoiceSelection() } }
    @Published var voiceMode: VoiceBridgeMode = .rehearsal { didSet { saveVoiceSelection() } }
    @Published var voiceInstructions = VoiceConversationInstructions.defaultConversation
    @Published var voiceDataAcknowledged = false {
        didSet {
            guard !restoringVoicePreferences else { return }
            voicePersistence.saveDataAcknowledgement(voiceDataAcknowledged)
        }
    }
    @Published var voiceRoutesAcknowledged = false {
        didSet {
            guard !restoringVoicePreferences, !restoringVoiceRouteAcknowledgement else { return }
            voicePersistence.saveExternalRoutingAcknowledgement(voiceRoutesAcknowledged, inputUID: voiceInputUID,
                                                               outputUID: voiceOutputUID, mode: voiceMode)
            restoreVoiceRouteAcknowledgement()
        }
    }
    @Published var voiceStartError: String?
    @Published var page: DeskPage = .desk
    @Published var route: DeskRoute = .phone
    @Published var recipient = ""
    @Published var numberText = ""
    @Published var brief = ""
    @Published var lifecycle = CallLifecycle()
    @Published var activity: [DeskActivity] = []
    @Published var whatsappInstalled = false
    @Published var phoneInstalled = false
    @Published var openingWhatsApp = false
    @Published var notice: String?
    @Published var pendingNumber: PhoneNumber?
    @Published var pendingRecipient = ""
    @Published var showReview = false
    @Published var showEndConfirmation = false
    @Published var refreshedAt = Date()

    init() {
        refreshApplications()
        restoreVoiceSelection()
        voicePersistenceObservation = voicePersistence.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        loadSavedVoiceKey()
        sambhaControl.onChange = { [weak self] in self?.objectWillChange.send() }
        voice.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .transcript(let transcript):
                self.sambhaControl.recordTranscript(role: transcript.speaker == .caller ? "INPUT" : "AI", text: transcript.text)
            case .state(.failed(let message)): self.sambhaControl.voiceStopped(error: message)
            case .conversationCompleted:
                let automatic = self.sambhaControl.ownsVoice
                self.sambhaControl.voiceStopped(error: nil)
                self.notice = automatic ? "Nox finished speaking. Solar is checking Phone’s hangup control."
                    : "Nox finished speaking. Check Phone and end the call separately."
            default: break // VoiceBridge emits internal idle on start; nonfatal notices keep Listening.
            }
        }
        diagnosticObservation = diagnostic.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        if UserDefaults.standard.bool(forKey: "sambha.controlEnabled.v1") { enableSambhaControl() }
    }

    private func saveVoiceSelection() {
        guard !restoringVoicePreferences else { return }
        voicePersistence.saveSelection(inputUID: voiceInputUID, outputUID: voiceOutputUID, mode: voiceMode)
        restoreVoiceRouteAcknowledgement()
    }
    private func restoreVoiceRouteAcknowledgement() {
        restoringVoiceRouteAcknowledgement = true
        voiceRoutesAcknowledged = voicePersistence.externalRoutingAcknowledged(inputUID: voiceInputUID,
                                                                              outputUID: voiceOutputUID, mode: voiceMode)
        restoringVoiceRouteAcknowledgement = false
    }
    func restoreVoiceSelection() {
        guard !voice.state.isActive, !voiceStartPending, !sambhaControl.hasReservedWork else { return }
        restoringVoicePreferences = true
        voice.refreshDevices()
        let restored = voicePersistence.restoreSelection(devices: voice.devices)
        voiceMode = restored.mode
        voiceInput = restored.input?.id ?? 0; voiceOutput = restored.output?.id ?? 0
        voiceInputUID = restored.input?.uid; voiceOutputUID = restored.output?.uid
        voiceDataAcknowledged = voicePersistence.dataAcknowledged
        restoreVoiceRouteAcknowledgement()
        voicePreferenceNotice = restored.notice
        restoringVoicePreferences = false
    }
    func loadSavedVoiceKey() {
        guard voicePersistence.keyOptIn, !voicePersistence.credentialBusy else { return }
        let revision = voiceKeyFieldGeneration
        credentialTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let key = await self.voicePersistence.loadSavedKey(unedited: { [weak self] in self?.voiceKeyFieldGeneration == revision })
            guard !Task.isCancelled, self.voiceKeyFieldGeneration == revision, let key else { return }
            self.voiceAPIKey = key
        }
    }
    func saveVoiceKeyExplicitly() {
        guard !voicePersistence.credentialBusy else { return }
        let key = voiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        credentialTask = Task { @MainActor [weak self] in _ = await self?.voicePersistence.saveKeyExplicitly(key) }
    }
    func forgetSavedVoiceKey() {
        voiceAPIKey = ""
        credentialTask?.cancel()
        credentialTask = Task { @MainActor [weak self] in _ = await self?.voicePersistence.forgetSavedKey() }
    }

    func stopAudioWork() {
        sambhaControl.voiceStopped(error: nil)
        voiceStartGeneration = UUID()
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceStartPending = false
        voice.stop()
        diagnostic.stop()
    }

    func beginVoiceStart(fromSambha: Bool = false) -> UUID? {
        guard !voice.state.isActive, !voiceStartPending, !diagnostic.state.isActive, fromSambha || !sambhaControl.hasReservedWork else { return nil }
        let token = UUID()
        voiceStartGeneration = token
        voiceStartPending = true
        return token
    }

    func isCurrentVoiceStart(_ token: UUID) -> Bool { voiceStartGeneration == token }

    func finishVoiceStart(_ token: UUID) {
        guard isCurrentVoiceStart(token) else { return }
        voiceStartPending = false
        voiceStartTask = nil
    }

    var validNumber: PhoneNumber? { try? PhoneNumber(numberText) }
    var numberError: String? {
        guard !numberText.isEmpty else { return nil }
        do { _ = try PhoneNumber(numberText); return nil }
        catch { return error.localizedDescription }
    }
    var handoffOutstanding: Bool { !lifecycle.canStartNewCall }

    func refreshApplications() {
        whatsappInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") != nil
        phoneInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mobilephone") != nil
        refreshedAt = Date()
    }

    func openWhatsApp() {
        guard !openingWhatsApp, !handoffOutstanding, !diagnostic.state.isActive, !sambhaControl.hasReservedWork else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") else {
            whatsappInstalled = false
            notice = "WhatsApp was not found on this Mac."
            return
        }
        openingWhatsApp = true
        notice = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] app, error in
            let opened = app != nil && error == nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.openingWhatsApp = false
                if opened {
                    self.record("WhatsApp opened", "App launch only. Choose a recipient and start the call in WhatsApp.", "message.fill")
                    self.notice = "WhatsApp opened. Choose a recipient there; you will speak on the call."
                } else {
                    self.record("WhatsApp launch failed", "The app could not be opened. No call was requested.", "exclamationmark.triangle")
                    self.notice = "WhatsApp could not be opened. No call was requested."
                }
            }
        }
    }

    func reviewPhoneHandoff() {
        guard !handoffOutstanding, !diagnostic.state.isActive, !sambhaControl.hasReservedWork, let number = validNumber, phoneInstalled else { return }
        pendingNumber = number
        pendingRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        showReview = true
    }

    func submitPhoneHandoff() {
        guard let number = pendingNumber else { return }
        do { try requestPhoneHandoff(number: number, recipient: pendingRecipient) }
        catch { notice = error.localizedDescription }
    }
    func requestPhoneHandoff(number: PhoneNumber, recipient: String, fromSambha: Bool = false) throws {
        guard !handoffOutstanding, !diagnostic.state.isActive, fromSambha || !sambhaControl.hasReservedWork,
              let url = URL(string: "tel:" + number.normalized),
              let phoneURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mobilephone") else {
            throw NSError(domain: "SolarCallDesk.Phone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Phone handoff is unavailable or another handoff is outstanding."])
        }
        let attempt = UUID()
        guard lifecycle.reduce(.begin(attempt)) else { throw NSError(domain: "SolarCallDesk.Phone", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another Phone handoff is outstanding."]) }
        pendingNumber = number; pendingRecipient = recipient
        showReview = false
        notice = nil
        // URL acceptance is a handoff request, never evidence of a live call.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: phoneURL, configuration: configuration) { [weak self] app, error in
            let accepted = app != nil && error == nil
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle.activeAttemptID == attempt else { return }
                if accepted {
                    self.lifecycle.reduce(.requestSubmitted(attempt))
                    self.lifecycle.reduce(.externalCallStatusUnavailable(attempt))
                    self.record("Phone handoff requested", "Number \(number.masked). Live call status is unknown.", "arrow.up.forward.app")
                } else {
                    // A failed open cannot prove whether the calling app acted.
                    self.lifecycle.reduce(.requestOutcomeUnknown(attempt))
                    self.record("Phone handoff could not be confirmed", "Number \(number.masked). Check Phone before another attempt.", "exclamationmark.triangle")
                }
            }
        }
    }

    func confirmUserEnded(fromSambha: Bool = false) {
        guard let attempt = lifecycle.activeAttemptID,
              lifecycle.reduce(.userConfirmedEnded(attempt)) else { return }
        if sambhaPhoneAttemptID == attempt {
            if !fromSambha { sambhaControl.userReportedEndFromUI() }
            if let jobID = phoneVisualControl.report.jobID { phoneVisualControl.reconcileUserReportedEnd(jobID: jobID) }
        }
        showEndConfirmation = false
        record("Call ended · user reported", "You confirmed the call is over or was never started in the calling app.", "checkmark.circle")
        notice = "You reported the call ended. The desk is ready for another handoff."
        pendingNumber = nil
        pendingRecipient = ""
    }

    private func record(_ title: String, _ detail: String, _ symbol: String) {
        activity.insert(DeskActivity(title: title, detail: detail, symbol: symbol), at: 0)
    }
}

enum Palette {
    static let navy = Color(red: 0.07, green: 0.14, blue: 0.20)
    static let ink = Color(red: 0.12, green: 0.20, blue: 0.25)
    static let muted = Color(red: 0.40, green: 0.47, blue: 0.51)
    static let teal = Color(red: 0.00, green: 0.45, blue: 0.42)
    static let mint = Color(red: 0.90, green: 0.96, blue: 0.94)
    static let canvas = Color(red: 0.96, green: 0.97, blue: 0.96)
    static let border = Color(red: 0.88, green: 0.91, blue: 0.90)
    static let amber = Color(red: 0.59, green: 0.36, blue: 0.12)
}

struct DeskView: View {
    @EnvironmentObject private var desk: DeskModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Palette.amber).frame(width: 6, height: 6)
                    Text("Prototype · Phone/WhatsApp audio routing unverified")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    HeaderVoiceControl(voice: desk.voice, diagnostic: desk.diagnostic)
                }
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 32).padding(.top, 23).padding(.bottom, 17)
                Rectangle().fill(Palette.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                        switch desk.page {
                        case .desk: CallDeskPage()
                        case .connections: ConnectionsPage()
                        case .voiceLab: VoiceLabPage(voice: desk.voice, diagnostic: desk.diagnostic)
                        case .activity: ActivityPage()
                        }
                    }
                    .frame(maxWidth: 840, alignment: .leading)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(Palette.canvas)
        }
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $desk.showReview) { PhoneReview() }
        .sheet(isPresented: $desk.showEndConfirmation) { EndConfirmation() }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 23)).foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(Palette.teal, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Solar").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("CALL DESK").font(.system(size: 9, weight: .bold)).tracking(2.6).opacity(0.56)
                }.foregroundStyle(.white)
            }
            .padding(.top, 51).padding(.bottom, 42).padding(.horizontal, 23)

            VStack(spacing: 7) {
                ForEach(DeskPage.allCases) { page in
                    Button { desk.page = page } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.symbol).font(.system(size: 16)).frame(width: 22)
                            Text(page.rawValue).font(.system(size: 13, weight: .medium))
                            Spacer()
                            if page == .activity && !desk.activity.isEmpty {
                                Text("\(desk.activity.count)").font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.white.opacity(0.10), in: Capsule())
                            }
                        }
                        .foregroundStyle(desk.page == page ? .white : .white.opacity(0.62))
                        .padding(.horizontal, 13).padding(.vertical, 13)
                        .background(desk.page == page ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("navigation-\(page.id)")
                }
            }.padding(.horizontal, 13)
            Spacer(minLength: 60)
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.45, green: 0.73, blue: 0.65)).frame(width: 5, height: 5)
                    Text("ON THIS MAC").font(.system(size: 9, weight: .bold)).tracking(1.4)
                }.foregroundStyle(.white.opacity(0.63))
                Text("A place to prepare.\nYou speak in the calling app.")
                    .font(.system(size: 12)).lineSpacing(4).foregroundStyle(.white.opacity(0.68))
                Text("v0.1 · Local prototype").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            }.padding(24)
        }
        .frame(width: 218)
        .background(Palette.navy)
    }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow).font(.system(size: 10, weight: .bold)).tracking(1.9).foregroundStyle(Palette.teal)
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.6)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.muted)
        }
    }
}

struct CallDeskPage: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        PageHeading(eyebrow: "CALL PREPARATION", title: "Your call desk", subtitle: "Prepare a call on this Mac.")

        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("CALLING APP").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(Palette.muted)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(DeskRoute.allCases) { route in
                        Button { desk.route = route; desk.notice = nil } label: {
                            Label(route.rawValue, systemImage: route.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 17).padding(.vertical, 8)
                                .foregroundStyle(desk.route == route ? Palette.teal : Palette.muted)
                                .background(desk.route == route ? .white : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
            }
            if desk.route == .whatsapp { WhatsAppCard() } else { PhoneCard() }
        }
        .padding(23).cardSurface()

        if desk.handoffOutstanding { PendingHandoffCard() }
        if let notice = desk.notice {
            Label(notice, systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(Palette.teal)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 10))
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Conversation brief", systemImage: "text.alignleft").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("OPTIONAL").font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(Palette.muted)
            }
            ZStack(alignment: .topLeading) {
                if desk.brief.isEmpty {
                    Text("What would you like to cover on the call?")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted.opacity(0.72))
                        .padding(.horizontal, 6).padding(.top, 8).allowsHitTesting(false)
                }
                TextEditor(text: $desk.brief)
                    .font(.system(size: 12)).scrollContentBackground(.hidden)
                    .frame(height: 66).accessibilityLabel("Conversation brief")
            }
            Text("Kept on this screen; not sent to either app.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(20).cardSurface()

        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "waveform").font(.system(size: 21)).foregroundStyle(Palette.teal)
                .frame(width: 42, height: 42).background(Palette.mint, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("AI conversation").font(.system(size: 13, weight: .semibold))
                Text("Configure voice here; enable Sambha control in Connections.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button("Open Voice lab") { desk.page = .voiceLab }.buttonStyle(PrimaryButtonStyle())
                .help("Open voice setup without starting audio or placing a call.")
        }
        Text("Call preparation is local. Voice lab is a separate, explicitly started API session. Closing the app stops it.")
            .font(.system(size: 10)).foregroundStyle(Palette.muted)
    }
}

struct WhatsAppCard: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "message.fill").font(.system(size: 24)).foregroundStyle(Palette.teal)
                    .frame(width: 54, height: 54).background(Palette.mint, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        Text("Continue in WhatsApp").font(.system(size: 19, weight: .semibold))
                        StatusPill(text: desk.whatsappInstalled ? "Installed" : "Not found", good: desk.whatsappInstalled)
                    }
                    Text("Open the app, select your recipient, then start a call.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }.padding(.top, 3)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle").font(.system(size: 13)).foregroundStyle(Palette.teal)
                Text("You will speak in WhatsApp. Solar has no live audio connection to consumer WhatsApp calls.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("App launch only · no recipient sent").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button { desk.openWhatsApp() } label: {
                    Label(desk.openingWhatsApp ? "Opening…" : "Open WhatsApp", systemImage: "arrow.up.right")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!desk.whatsappInstalled || desk.openingWhatsApp || desk.handoffOutstanding || desk.diagnostic.state.isActive)
                .accessibilityIdentifier("open-whatsapp")
            }
        }
    }
}

struct PhoneCard: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                Image(systemName: "phone.fill").font(.system(size: 23)).foregroundStyle(Palette.teal)
                    .frame(width: 50, height: 50).background(Palette.mint, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        Text("Prepare a Phone handoff").font(.system(size: 19, weight: .semibold))
                        StatusPill(text: desk.phoneInstalled ? "Installed" : "Not found", good: desk.phoneInstalled)
                    }
                    Text("Review the number before opening it in your Mac calling app.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recipient name").font(.system(size: 11, weight: .medium))
                    TextField("Optional", text: $desk.recipient).textFieldStyle(.plain).inputSurface()
                        .accessibilityLabel("Recipient name")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("International number").font(.system(size: 11, weight: .medium))
                    TextField("+ country code and number", text: $desk.numberText).textFieldStyle(.plain).inputSurface()
                        .accessibilityLabel("International phone number")
                }
            }.disabled(desk.handoffOutstanding)
            if let error = desk.numberError {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.amber)
            } else if let number = desk.validNumber {
                Label("Ready to review: \(number.normalized)", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Palette.teal)
            } else {
                Text("Include + and country code. Formatting spaces and hyphens are accepted.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .center, spacing: 14) {
                Text("You speak on the call. Relay availability and call status must be checked in Phone.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 5)
                Button { desk.reviewPhoneHandoff() } label: { Label("Review handoff", systemImage: "arrow.right") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(desk.validNumber == nil || !desk.phoneInstalled || desk.handoffOutstanding || desk.diagnostic.state.isActive)
                    .accessibilityIdentifier("review-phone-handoff")
            }
        }
    }
}

struct PendingHandoffCard: View {
    @EnvironmentObject private var desk: DeskModel
    private var automatic: Bool { desk.sambhaPhoneAttemptID != nil && desk.sambhaPhoneAttemptID == desk.lifecycle.activeAttemptID }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Handoff requested · live call status unknown", systemImage: "arrow.up.forward.app")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.amber)
            Text(automatic
                 ? "Solar is handling the verified Call and Hang Up controls for this Sambha job. Keep Phone visible. If automatic hangup cannot be verified, the job stays locked and reports the reason."
                 : "Check the calling app. Solar cannot confirm whether this call started, connected or ended. Another handoff stays locked until you confirm the call is over or was never started.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Button("I ended the call") { desk.showEndConfirmation = true }
                .buttonStyle(SecondaryButtonStyle())
        }.padding(19).background(Color(red: 0.99, green: 0.96, blue: 0.89), in: RoundedRectangle(cornerRadius: 13))
    }
}

struct ConnectionsPage: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        PageHeading(eyebrow: "KNOW WHAT IS CONNECTED", title: "Connections", subtitle: "Installed apps can open. Installation does not establish a live audio bridge.")
        SambhaControlCard()
        PhoneControlSetupCard()
        VStack(alignment: .leading, spacing: 0) {
            ConnectionRow(symbol: "message.fill", title: "WhatsApp launcher", detail: desk.whatsappInstalled ? "Available · open the installed consumer app" : "Unavailable · app not found", available: desk.whatsappInstalled)
            Divider().padding(.leading, 60)
            ConnectionRow(symbol: "phone.fill", title: "Phone handoff", detail: desk.phoneInstalled ? "Available · hand a reviewed number to a calling app" : "Unavailable · Phone app not found", available: desk.phoneInstalled)
            Divider().padding(.leading, 60)
            ConnectionRow(symbol: "ear.badge.waveform", title: "Receive live call audio", detail: "Experimental · configure selected virtual buses in Voice lab", available: false)
            Divider().padding(.leading, 60)
            ConnectionRow(symbol: "waveform", title: "Send AI speech into a call", detail: "Experimental · Voice lab can send AI speech over the selected output", available: false)
        }.padding(.horizontal, 19).cardSurface()
        HStack {
            Text("App check: \(desk.refreshedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Spacer()
            Button { desk.refreshApplications() } label: { Label("Refresh app check", systemImage: "arrow.clockwise") }
                .buttonStyle(SecondaryButtonStyle())
        }
        VStack(alignment: .leading, spacing: 14) {
            Label("What is needed for AI conversation?", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 16, weight: .semibold))
            Text("Voice lab can receive selected input audio and send AI speech through configured virtual buses. Phone answer and hangup cannot be observed here; a person must supervise and check Phone.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text("Apple’s microphone injection and telephony speech mixing APIs are unavailable on macOS. Voice lab offers a separate API session, with experimental external routing. WhatsApp Business Calling is a separate service that requires a decision and configuration.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://developer.apple.com/documentation/avfaudio/avaudioapplication")!) {
                    Label("Apple audio documentation", systemImage: "arrow.up.right")
                }
                Link(destination: URL(string: "https://developers.facebook.com/documentation/business-messaging/whatsapp/calling")!) {
                    Label("WhatsApp Business Calling", systemImage: "arrow.up.right")
                }
            }.font(.system(size: 11, weight: .medium)).tint(Palette.teal)
        }.padding(22).cardSurface()
        PrivacyNote()
    }
}

struct ConnectionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let available: Bool
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(available ? Palette.teal : Palette.muted)
                .frame(width: 42, height: 42).background(available ? Palette.mint : Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Palette.teal : Palette.muted.opacity(0.6))
        }.padding(.vertical, 18)
    }
}

struct ActivityPage: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        PageHeading(eyebrow: "ONLY WHAT HAPPENED HERE", title: "Activity", subtitle: "Local actions from this session. Phone numbers are masked.")
        if desk.activity.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.teal)
                    .frame(width: 76, height: 76).background(Palette.mint, in: RoundedRectangle(cornerRadius: 24))
                Text("A fresh start").font(.system(size: 19, weight: .semibold))
                Text("App launches and call handoffs appear here.\nThere are no call transcripts or live call events.")
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                Button("Go to call desk") { desk.page = .desk }.buttonStyle(SecondaryButtonStyle())
            }.padding(.vertical, 65).frame(maxWidth: .infinity).cardSurface()
        } else {
            VStack(spacing: 0) {
                ForEach(desk.activity) { event in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: event.symbol).font(.system(size: 17)).foregroundStyle(Palette.teal)
                            .frame(width: 36, height: 36).background(Palette.mint, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.title).font(.system(size: 13, weight: .semibold))
                            Text(event.detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(event.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.padding(20)
                    if event.id != desk.activity.last?.id { Divider().padding(.leading, 70) }
                }
            }.cardSurface()
        }
        PrivacyNote()
    }
}

struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield").foregroundStyle(Palette.teal)
            Text("Call desk briefs, test results and activity stay in memory. The local bus test uploads no audio. The API voice session sends instructions and selected input audio to OpenAI only after you start it. No recording to disk or telemetry. Audio devices and session mode are saved locally; API keys stay in memory unless explicitly saved in this Mac’s Keychain. Quit to clear the session.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PhoneReview: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            Image(systemName: "phone.arrow.up.right").font(.system(size: 27)).foregroundStyle(Palette.teal)
                .frame(width: 58, height: 58).background(Palette.mint, in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 9) {
                Text("Review your handoff").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("The Mac calling app will receive this exact number.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !desk.pendingRecipient.isEmpty { Text(desk.pendingRecipient).font(.system(size: 13, weight: .medium)) }
                Text(desk.pendingNumber?.normalized ?? "").font(.system(size: 25, weight: .semibold, design: .monospaced)).textSelection(.enabled)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 7) {
                Label("You will speak on this call", systemImage: "person.crop.circle").font(.system(size: 13, weight: .semibold))
                Text("Opening this number may start a call or show a confirmation. This manual handoff does not start Nox or the automatic Sambha controls.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { desk.showReview = false }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button { desk.submitPhoneHandoff() } label: { Label("Open in Phone", systemImage: "arrow.up.right") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(desk.handoffOutstanding || desk.pendingNumber == nil || desk.diagnostic.state.isActive)
                    .accessibilityIdentifier("confirm-phone-handoff")
            }
        }.padding(30).frame(width: 490).background(.white)
    }
}

struct EndConfirmation: View {
    @EnvironmentObject private var desk: DeskModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Check the calling app first").font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Confirm the call has ended or was never started. This records your report and unlocks another handoff; it does not end a call in Phone or WhatsApp.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep locked") { desk.showEndConfirmation = false }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("I checked · call is over") { desk.confirmUserEnded() }.buttonStyle(PrimaryButtonStyle())
            }
        }.padding(30).frame(width: 490).background(.white)
    }
}

struct StatusPill: View {
    let text: String
    let good: Bool
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .foregroundStyle(good ? Palette.teal : Palette.amber)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(good ? Palette.mint : Color.orange.opacity(0.09), in: Capsule())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(enabled ? Color.white : Palette.muted.opacity(0.7))
            .background(enabled ? Palette.teal.opacity(configuration.isPressed ? 0.8 : 1) : Palette.border, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 9).foregroundStyle(Palette.teal)
            .background(configuration.isPressed ? Palette.mint : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
    }
}

extension View {
    func cardSurface() -> some View {
        self.background(.white, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.border.opacity(0.8), lineWidth: 1))
    }
    func inputSurface() -> some View {
        self.font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 11)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
    }
}
