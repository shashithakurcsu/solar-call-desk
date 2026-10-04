import AppKit
@preconcurrency import ApplicationServices
import Combine
import Foundation
import CallCore

/// Bounded read-only discovery. This class never authorizes or performs call actions.
@MainActor public final class PhoneControlProbe: ObservableObject {
    @Published public private(set) var state: PhoneControlProbeState = .idle
    @Published public private(set) var status = "Phone controls have not been inspected."
    @Published public private(set) var report: PhoneControlReport?

    private let queue = DispatchQueue(label: "SolarCallDesk.PhoneControlProbe", qos: .utility)
    private let candidates: @MainActor () -> [PhoneProbeCandidate]
    private let permission: @MainActor () -> Bool
    private let worker: @Sendable ([PhoneProbeCandidate], PhoneNumber?, PhoneProbeCancellation) -> PhoneControlReport
    private var generation = UUID()
    private var cancellation: PhoneProbeCancellation?
    private(set) var workerBusy = false

    public init() {
        candidates = Self.captureCandidates
        permission = { AXIsProcessTrusted() }
        worker = { PhoneProbeScanner.live(candidates: $0, expected: $1, cancellation: $2) }
    }

    /// Offline dependency injection. AX providers are constructed inside the worker closure.
    init(candidates: @escaping @MainActor () -> [PhoneProbeCandidate],
         permission: @escaping @MainActor () -> Bool,
         worker: @escaping @Sendable ([PhoneProbeCandidate], PhoneNumber?, PhoneProbeCancellation) -> PhoneControlReport) {
        self.candidates = candidates; self.permission = permission; self.worker = worker
    }

    private static func captureCandidates() -> [PhoneProbeCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated, let bundle = application.bundleIdentifier,
                  PhoneProbePrivacy.bundles.contains(bundle), let url = application.bundleURL,
                  PhoneProbePrivacy.trustedPath(bundle: bundle, path: url.resolvingSymlinksInPath().standardizedFileURL.path)
            else { return nil }
            var candidate = PhoneProbeCandidate(bundleIdentifier: bundle, processIdentifier: application.processIdentifier,
                                                bundlePath: url.resolvingSymlinksInPath().standardizedFileURL.path,
                                                launchTime: application.launchDate?.timeIntervalSince1970)
            if candidate.isEmbeddedPhoneOwner {
                candidate.processStart = PhoneProbeProcessMetadata.startTime(pid: candidate.processIdentifier)
            }
            return candidate
        }.sorted {
            if $0.isMainPhone != $1.isMainPhone { return $0.isMainPhone }
            if $0.bundleIdentifier != $1.bundleIdentifier { return $0.bundleIdentifier < $1.bundleIdentifier }
            return $0.processIdentifier < $1.processIdentifier
        }
    }

    /// Returns immediately; repeated starts during a scan do not schedule another scan.
    public func start(expectedNumber: String? = nil) {
        guard state != .running else { return }
        guard !workerBusy else {
            status = "Previous inspection is stopping. Inspect again after its current accessibility message finishes."
            return
        }
        let expected: PhoneNumber?
        do {
            expected = try expectedNumber.map {
                let parsed = try PhoneNumber($0)
                guard parsed.normalized == $0 else { throw PhoneNumber.ValidationError.invalidCharacters }
                return parsed
            }
        }
        catch {
            var result = PhoneControlReport(metadataOnly: true, permissionGranted: false)
            result.errors = ["Use an international target in canonical form: + followed by 8–15 digits, without spaces or punctuation. No inspection was started."]
            report = result; state = .finished; status = result.errors[0]; return
        }
        guard permission() else {
            var result = PhoneControlReport(metadataOnly: expected == nil, permissionGranted: false)
            result.errors = ["Accessibility is not allowed. Grant it in System Settings, then inspect again. This probe does not request permission."]
            report = result; state = .finished; status = result.errors[0]; return
        }
        let captured = candidates(), token = PhoneProbeCancellation(), current = UUID(), operation = worker
        generation = current; cancellation = token; report = nil; state = .running
        workerBusy = true
        status = "Inspecting Phone accessibility metadata (read only)…"
        queue.async { [weak self] in
            let result = operation(captured, expected, token)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.workerBusy = false
                guard self.generation == current, !token.isCancelled else { return }
                self.report = result; self.cancellation = nil; self.state = .finished
                if result.candidates.isEmpty {
                    self.status = "No approved Phone process was inspected. Call status remains unknown."
                } else if result.metadataOnly {
                    self.status = "Window metadata inspected. Supply a target number to inspect restricted call panels."
                } else if result.targetMatched {
                    self.status = "Exact target text found. Call state and automatic controls remain unverified."
                } else {
                    self.status = "Inspection finished; no exact target binding established. Call status remains unknown."
                }
                if result.truncated { self.status += " The bounded scan was truncated." }
                if !result.errors.isEmpty { self.status += " Some accessibility reads failed." }
            }
        }
    }

    /// Stops subsequent reads; an in-flight synchronous AX message finishes under its messaging timeout.
    public func cancel() {
        guard state == .running else { return }
        cancellation?.cancel(); cancellation = nil; generation = UUID()
        state = .cancelled; status = "Inspection cancelled. Call status remains unknown."
    }

    public func reportJSON() -> String? {
        guard let report else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
