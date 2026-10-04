import Foundation
import Combine
import CoreGraphics
@preconcurrency import ApplicationServices
import CallCore

@MainActor public final class PhoneVisualController: ObservableObject {
    @Published public private(set) var report = PhoneVisualReport()
    public var observation: PhoneVisualObservation { report.observation }
    public var status: String { report.status }
    private let provider: any PhoneVisualProvider
    private var job: (UUID, PhoneNumber)?
    private var baseline: PhoneVisualContext?
    private var settled = false
    private var seenJobs: Set<UUID> = []
    private var cancellation: PhoneVisualCancellation?
    private var busy = false
    private var pendingUserReconciliation: UUID?
    private var userReconciled = false

    public init() { provider = PhoneVisualLiveProvider() }
    init(provider: any PhoneVisualProvider) { self.provider = provider }
    public func permissions() -> PhoneVisualPermissions {
        PhoneVisualPermissions(accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess())
    }
    /// Permission prompt only; the app must invoke this from an explicit setup action.
    public static func requestScreenCaptureAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Initialize local OCR on generated nonpersonal pixels before any handoff, audio or API work.
    /// A timed-out framework request drains without permitting later actions or a second worker.
    public func warmUp() async -> Bool {
        guard !busy else { return false }
        busy = true; report.busy = true
        let token = PhoneVisualCancellation(), completion = PhoneVisualWarmupCompletion(), operation = provider
        cancellation = token
        let work = Task.detached(priority: .utility) { [weak self] in
            let success: Bool
            do { try await operation.warmUp(); success = true } catch { success = false }
            await MainActor.run { [weak self] in
                guard let self, self.cancellation === token else { return }
                self.finish()
                if !self.userReconciled {
                    self.report.status = success && !token.isCancelled
                        ? "Local OCR warmed using synthetic pixels. No Phone capture or click occurred."
                        : "Local OCR warmup stopped or failed; no Phone handoff or click occurred."
                }
            }
            completion.complete(success && !token.isCancelled)
        }
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            token.cancel(); completion.complete(false)
        }
        let result = await withTaskCancellationHandler {
            await completion.value()
        } onCancel: {
            token.cancel(); completion.complete(false)
        }
        timer.cancel()
        if !result { report.status = "Local OCR warmup did not finish within its setup budget. No Phone handoff or click occurred." }
        _ = work // Work deliberately drains after timeout/cancellation; it never performs actions.
        return result
    }

    public func prepare(jobID: UUID, expectedNumber: String) throws {
        guard !busy else { throw PhoneVisualError.busy }
        guard let number = try? PhoneNumber(expectedNumber), number.normalized == expectedNumber else { throw PhoneVisualError.invalidNumber }
        if let job, job.0 == jobID {
            guard job.1 == number else { throw PhoneVisualError.jobMismatch }; return
        }
        guard !report.confirmationClickPosted || settled else { throw PhoneVisualError.activeJob }
        guard !seenJobs.contains(jobID), seenJobs.count < 256 else { throw PhoneVisualError.jobMismatch }
        seenJobs.insert(jobID); job = (jobID, number); baseline = nil; settled = false; userReconciled = false
        report = PhoneVisualReport(); report.jobID = jobID
        report.status = "Prepared a target-bound visual job. No click has been requested."
    }
    public func cancel() {
        cancellation?.cancel(); report.observation = .unknown
        report.status = "Stopping visual work; committed click receipts and the job remain available for hangup."
        report.canConfirm = false; report.canHangup = report.confirmationClickPosted && !report.hangupAttempted && !busy
    }
    public func reconcileUserReportedEnd(jobID: UUID) {
        guard job?.0 == jobID else { report.status = PhoneVisualError.jobMismatch.errorDescription!; return }
        if busy {
            pendingUserReconciliation = jobID; cancellation?.cancel()
            report.observation = .unknown; report.canConfirm = false; report.canHangup = false
            report.status = "User reported call end; waiting for visual work to drain. Carrier state remains unknown."
            return
        }
        settled = true; userReconciled = true; report.observation = .unknown; report.canConfirm = false; report.canHangup = false
        report.status = "User reported call end. Carrier state remains unknown."
    }
    public func reportJSON() -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) }
    }
    private func begin() throws -> (PhoneNumber, PhoneVisualCancellation, Double) {
        guard !busy else { throw PhoneVisualError.busy }
        guard let job, !settled else { throw PhoneVisualError.jobMismatch }
        busy = true; report.busy = true
        let token = PhoneVisualCancellation(); cancellation = token
        return (job.1, token, ProcessInfo.processInfo.systemUptime)
    }
    private func finish() {
        busy = false; report.busy = false; cancellation = nil
        if let pendingUserReconciliation, pendingUserReconciliation == job?.0 {
            self.pendingUserReconciliation = nil; settled = true; userReconciled = true; report.observation = .unknown
            report.status = "User reported call end. Carrier state remains unknown."
        }
        report.canConfirm = report.observation == .confirmation && !report.confirmationAttempted
        report.canHangup = report.confirmationClickPosted && !report.hangupAttempted && !settled
    }
    private func check(_ token: PhoneVisualCancellation, started: Double) throws {
        guard !token.isCancelled else { throw PhoneVisualError.cancelled }
        guard ProcessInfo.processInfo.systemUptime - started < 24 else { throw PhoneVisualError.deadline }
    }
    private func context(_ token: PhoneVisualCancellation, started: Double) async throws -> PhoneVisualContext {
        try check(token, started: started)
        guard (await provider.permissions()).granted else { throw PhoneVisualError.permission }
        let current = try await provider.context(); try check(token, started: started)
        if let baseline {
            guard baseline.identities == current.identities, baseline.hostPID == current.hostPID else { throw PhoneVisualError.process }
            if !current.absent {
                if baseline.absent { self.baseline = current }
                else { guard baseline.windowID == current.windowID, baseline.bridgeBounds == current.bridgeBounds else { throw PhoneVisualError.changed } }
            }
        } else { baseline = current }
        return current
    }
    private func analyze(_ frame: PhoneVisualFrame, expected: PhoneNumber) async throws -> PhoneVisualAnalysis {
        try await Task.detached(priority: .utility) { try PhoneVisualAnalyzer.analyze(frame, expected: expected) }.value
    }
    private func failure(_ error: Error) {
        guard !userReconciled else { return }
        report.observation = .unknown
        report.status = (error as? PhoneVisualError)?.errorDescription ?? "Visual verification failed. No automatic retry will be attempted."
        report.canConfirm = false
    }
    public func inspect() async -> PhoneVisualReport {
        do {
            let (number, token, start) = try begin(); defer { finish() }
            let current = try await context(token, started: start)
            guard !current.absent else { throw PhoneVisualError.panel }
            let frame = try await provider.snapshot(current), result = try await analyze(frame, expected: number)
            try check(token, started: start)
            report.observation = result.observation; report.status = result.observation == .confirmation
                ? "Exact target confirmation and reviewed green control are visible. No click posted."
                : "Exact target call UI and reviewed red control are visible. Carrier state remains unknown."
        } catch { failure(error) }
        return report
    }
    public func confirm() async -> PhoneVisualReport {
        guard !report.confirmationAttempted else { report.status = "Confirmation was already attempted for this job; it will not be retried."; return report }
        do {
            let (number, token, start) = try begin(); defer { finish() }
            report.confirmationAttempted = true
            var pending: (PhoneVisualContext, PhoneVisualFrame, PhoneVisualAnalysis)?
            for _ in 0..<32 {
                try check(token, started: start)
                guard ProcessInfo.processInfo.systemUptime - start < 8 else { throw PhoneVisualError.panel }
                let current: PhoneVisualContext
                do { current = try await context(token, started: start) }
                catch let error as PhoneVisualError {
                    switch error {
                    case .process, .session:
                        try await Task.sleep(for: .milliseconds(250)); continue
                    default: throw error
                    }
                }
                if !current.absent {
                    let first = try await provider.snapshot(current), result = try await analyze(first, expected: number)
                    pending = (current, first, result); break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let (current, first, a) = pending else { throw PhoneVisualError.panel }
            guard a.observation == .confirmation else { throw PhoneVisualError.layout }
            try check(token, started: start)
            let freshContext = try await context(token, started: start)
            guard current == freshContext else { throw PhoneVisualError.changed }
            let second = try await provider.snapshot(freshContext), b = try await analyze(second, expected: number)
            guard PhoneVisualAnalyzer.unchanged(first, second, firstAnalysis: a, secondAnalysis: b),
                  ProcessInfo.processInfo.systemUptime - second.capturedAt < 2 else { throw PhoneVisualError.changed }
            try check(token, started: start)
            try await provider.click(b.button, context: freshContext, freshnessDeadline: second.capturedAt + 2, cancellation: token)
            // Preserve receipts even if cancel arrived while the committed event pair was returning.
            report.confirmationClickPosted = true; report.observation = .unknown
            report.status = "One confirmation click posted. Waiting for target call UI; carrier state remains unknown."
            for _ in 0..<8 {
                try check(token, started: start)
                let next = try await context(token, started: start)
                if !next.absent, let frame = try? await provider.snapshot(next),
                   let analysis = try? await analyze(frame, expected: number), analysis.observation == .callUIVisible {
                    try check(token, started: start); report.observation = .callUIVisible
                    report.status = "One confirmation click posted and target call UI observed. Carrier state remains unknown."
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch { failure(error) }
        return report
    }
    public func hangup() async -> PhoneVisualReport {
        guard report.confirmationClickPosted, !report.hangupAttempted else { report.status = "A committed confirmation and unused hangup attempt are required for this job."; return report }
        do {
            let (number, token, start) = try begin(); defer { finish() }
            report.hangupAttempted = true
            let current = try await context(token, started: start)
            guard !current.absent else { throw PhoneVisualError.panel }
            let first = try await provider.snapshot(current), a = try await analyze(first, expected: number)
            guard a.observation == .callUIVisible else { throw PhoneVisualError.layout }
            let freshContext = try await context(token, started: start)
            guard current == freshContext else { throw PhoneVisualError.changed }
            let second = try await provider.snapshot(freshContext), b = try await analyze(second, expected: number)
            guard PhoneVisualAnalyzer.unchanged(first, second, firstAnalysis: a, secondAnalysis: b),
                  ProcessInfo.processInfo.systemUptime - second.capturedAt < 2 else { throw PhoneVisualError.changed }
            try check(token, started: start)
            try await provider.click(b.button, context: freshContext, freshnessDeadline: second.capturedAt + 2, cancellation: token)
            report.hangupClickPosted = true; report.observation = .unknown
            report.status = "One target-bound hangup click posted. Panel closure remains unverified."
            var absences = 0
            for _ in 0..<8 {
                try check(token, started: start)
                let next = try await context(token, started: start)
                absences = next.absent ? absences + 1 : 0
                if absences == 2 {
                    settled = true; report.observation = .hangupRequestedPanelClosed
                    report.status = "Validated hangup click posted, then the same process session's panel was absent twice. Carrier state remains unknown."
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch { failure(error) }
        return report
    }
}
