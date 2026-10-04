import AVFoundation
import Combine
import SwiftUI
import VoiceBridge

@MainActor private final class MicrophoneAccessModel: ObservableObject {
    @Published var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var requesting = false
    func refresh() { status = AVCaptureDevice.authorizationStatus(for: .audio) }
    func requestAccess() {
        guard !requesting else { return }
        requesting = true
        Task { @MainActor in
            defer { requesting = false; refresh() }
            _ = try? await MicrophoneAuthorization.authorize(status: AVCaptureDevice.authorizationStatus(for: .audio)) {
                await AVCaptureDevice.requestAccess(for: .audio)
            }
        }
    }
}

struct MicrophoneAccessCard: View {
    @EnvironmentObject private var desk: DeskModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var voice: VoiceBridgeCoordinator
    @ObservedObject var diagnostic: VirtualLoopbackDiagnostic
    @StateObject private var access = MicrophoneAccessModel()
    private var status: AVAuthorizationStatus { access.status }

    private var busy: Bool {
        access.requesting || voice.state.isActive || desk.voiceStartPending || diagnostic.state.isActive || desk.sambhaControl.hasReservedWork
    }
    private var statusText: String {
        switch status {
        case .authorized: "Allowed"
        case .notDetermined: "Permission needed"
        case .denied: "Not allowed"
        case .restricted: "Restricted by macOS"
        @unknown default: "Permission unknown"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Microphone access", systemImage: "mic").font(.system(size: 15, weight: .semibold))
                Spacer()
                StatusPill(text: statusText, good: status == .authorized)
            }
            Text(status == .authorized
                 ? "macOS has saved microphone access for this copy of Solar. No Start/Stop session or repeated permission click is needed. You can revoke access in System Settings."
                 : "Allow access once before using Sambha. macOS remembers the decision for this app identity. This requests permission only; it starts no audio, API session, or call.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            if Bundle.main.object(forInfoDictionaryKey: "SolarSigningMode") as? String != "certificate" {
                Text("This development copy is ad-hoc signed. Rebuilding changes its identity and may require permission again; certificate signing is needed to keep the same identity across updates.")
                    .font(.system(size: 11)).foregroundStyle(Palette.amber)
            }
            if status == .denied || status == .restricted {
                Text("Allow Solar Call Desk in System Settings → Privacy & Security → Microphone, then refresh this status. A macOS restriction may require your administrator.")
                    .font(.system(size: 11)).foregroundStyle(Palette.amber)
            }
            HStack {
                if status == .notDetermined {
                    Button(access.requesting ? "Waiting for macOS…" : "Allow microphone access") {
                        guard !busy else { return }
                        access.requestAccess()
                    }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                }
                Spacer()
                Button("Refresh status") { access.refresh() }.buttonStyle(SecondaryButtonStyle()).disabled(busy)
            }
        }.padding(22).cardSurface()
            .onAppear { access.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { access.refresh() } }
    }
}
