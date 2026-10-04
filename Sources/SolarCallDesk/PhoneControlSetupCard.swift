import AppKit
@preconcurrency import ApplicationServices
import Combine
import SwiftUI
import PhoneControl

/// Permission setup only. Granting Accessibility is not proof that Phone's
/// confirmation, connected state, or hangup controls can be automated.
@MainActor private final class PhoneControlAccessModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var screenCapture = CGPreflightScreenCaptureAccess()
    @Published var targetNumber = ""
    func refresh() { trusted = AXIsProcessTrusted(); screenCapture = CGPreflightScreenCaptureAccess() }
    func requestScreenCapture() { screenCapture = CGRequestScreenCaptureAccess() }
    func requestAccess() {
        trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
    }
}

struct PhoneControlSetupCard: View {
    @EnvironmentObject private var desk: DeskModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var access = PhoneControlAccessModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Phone automation setup", systemImage: "phone.badge.checkmark")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                StatusPill(text: access.trusted && access.screenCapture ? "Permissions ready" : "Setup needed",
                           good: access.trusted && access.screenCapture)
            }
            Text("Sambha calls use local screenshots of the Phone popup to verify the exact number and press Call or Hang Up. Images stay on this Mac. This supports the tested popup layout; an unfamiliar or ambiguous view stops automation.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(access.trusted
                 ? "Accessibility is allowed for Solar. Screen Recording also needs to be allowed so Solar can verify the Phone popup. The buttons below request permissions only; they do not place calls or start audio."
                 : "Allow Accessibility once to let Solar inspect Phone’s call controls during setup. macOS controls this permission; this button does not dial, capture audio, or press Phone’s buttons.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                StatusPill(text: access.trusted ? "Accessibility allowed" : "Accessibility needed", good: access.trusted)
                Spacer()
                if !access.trusted {
                    Button("Allow Accessibility") { access.requestAccess() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(desk.sambhaBusy)
                }
                Button("Refresh status") { access.refresh() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            HStack {
                StatusPill(text: access.screenCapture ? "Screen Recording allowed" : "Screen Recording needed", good: access.screenCapture)
                Spacer()
                if !access.screenCapture {
                    Button("Allow Screen Recording") { access.requestScreenCapture() }
                        .buttonStyle(PrimaryButtonStyle()).disabled(desk.sambhaBusy)
                }
            }
            Text("The Mac must remain awake and logged in, with Phone’s popup visible during calls. Automatic call and hangup controls are implemented; a complete live Sambha test is still pending.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Divider()
            TextField("Expected phone number, optional (+country code)", text: $access.targetNumber)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Optional expected phone number for read-only inspection")
            Text("Inspection never starts a call or presses buttons. Without a number, it reads window metadata only. It does not search contacts or call history.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            PhoneProbeReadout(probe: desk.phoneControlProbe, expectedNumber: access.targetNumber, trusted: access.trusted)
        }.padding(22).cardSurface()
            .onAppear { access.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { access.refresh() } }
    }
}

private struct PhoneProbeReadout: View {
    @ObservedObject var probe: PhoneControlProbe
    let expectedNumber: String
    let trusted: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Inspect Phone controls") {
                    let value = expectedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                    probe.start(expectedNumber: value.isEmpty ? nil : value)
                }.buttonStyle(SecondaryButtonStyle()).disabled(!trusted || probe.state == .running)
                if probe.state == .running {
                    Button("Cancel inspection") { probe.cancel() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            Text(probe.status).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
        }
    }
}
