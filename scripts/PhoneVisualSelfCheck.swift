import Foundation
import CoreGraphics
import ImageIO
import CallCore
@testable import PhoneControl

private func check(_ condition: Bool, line: UInt = #line) { precondition(condition, "Fixture assertion at line \(line)") }

private func frame(active: Bool = false, number: String = "+13125550123", extraNumber: Bool = false,
                   unknownColor: Bool = false, extraPanel: Bool = false) -> PhoneVisualFrame {
    var bytes = [UInt8](repeating: 0, count: 722 * 256 * 4)
    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: [UInt8]) {
        for row in y..<(y + h) { for column in x..<(x + w) {
            let offset = (row * 722 + column) * 4
            for channel in 0..<4 { bytes[offset + channel] = color[channel] }
        } }
    }
    fill(40, 0, 682, active ? 220 : 156, [40, 40, 40, 255])
    if extraPanel { fill(0, 230, 400, 26, [40, 40, 40, 255]) }
    if active { fill(620, 140, 80, 80, unknownColor ? [20, 20, 230, 255] : [250, 10, 10, 255]) }
    else { fill(560, 24, 140, 50, unknownColor ? [20, 20, 230, 255] : [20, 230, 50, 255]) }
    var text = [PhoneVisualText(value: number, confidence: 1, bounds: PhoneVisualRect(x: 60, y: 10, width: 170, height: 16))]
    if !active { text.append(PhoneVisualText(value: "Click to Call", confidence: 1, bounds: PhoneVisualRect(x: 60, y: 32, width: 100, height: 12))) }
    if extraNumber { text.append(PhoneVisualText(value: "+442079460123", confidence: 1, bounds: PhoneVisualRect(x: 60, y: 50, width: 170, height: 16))) }
    return PhoneVisualFrame(width: 722, height: 256, rgba: Data(bytes), text: text, capturedAt: ProcessInfo.processInfo.systemUptime)
}

private func context(absent: Bool = false, start: UInt64 = 100) -> PhoneVisualContext {
    let candidate = PhoneProbeCandidate(bundleIdentifier: "com.apple.mobilephone", processIdentifier: 42,
                                         bundlePath: "/System/Applications/Phone.app", processStart: PhoneProbeProcessStart(seconds: start, microseconds: 0))
    let identity = PhoneVisualIdentity(candidate: candidate, start: candidate.processStart!)
    return PhoneVisualContext(identities: [identity], windowID: absent ? nil : 99, hostPID: 772,
                              windowBounds: absent ? nil : PhoneVisualRect(x: 0, y: 0, width: 1496, height: 967),
                              bridgeBounds: absent ? nil : PhoneVisualRect(x: 1119, y: 52, width: 361, height: 600), absent: absent)
}

private actor FixtureVisualProvider: PhoneVisualProvider {
    var permission = PhoneVisualPermissions(accessibility: true, screenCapture: true)
    var frames: [PhoneVisualFrame]
    var clicks = 0
    var forceChanged = false
    var missingPanelOnce = false
    var holdSnapshot = false
    var continuation: CheckedContinuation<Void, Never>?
    var firstFrame: PhoneVisualFrame
    var closedAfterHangup = true
    var processChangedAfterHangup = false
    var contextCalls = 0
    var startupProcessFailures = 0
    var expired = false
    init(_ frames: [PhoneVisualFrame] = [frame(), frame(), frame(active: true)]) {
        self.frames = frames; firstFrame = frames[0]
    }
    func configure(permission: PhoneVisualPermissions? = nil, changed: Bool = false, missingOnce: Bool = false,
                   hold: Bool = false, closed: Bool = true, processChangedAfterHangup: Bool = false, startupProcessFailures: Int = 0, expired: Bool = false) {
        if let permission { self.permission = permission }
        forceChanged = changed; missingPanelOnce = missingOnce; holdSnapshot = hold
        closedAfterHangup = closed; self.processChangedAfterHangup = processChangedAfterHangup
        self.startupProcessFailures = startupProcessFailures
        self.expired = expired
    }
    func permissions() -> PhoneVisualPermissions { permission }
    func context() throws -> PhoneVisualContext {
        contextCalls += 1
        if startupProcessFailures > 0 { startupProcessFailures -= 1; throw PhoneVisualError.process }
        if missingPanelOnce { missingPanelOnce = false; return SwiftContext(absent: true) }
        return SwiftContext(absent: clicks >= 2 && closedAfterHangup, start: clicks >= 2 && processChangedAfterHangup ? 101 : 100)
    }
    func snapshot(_ context: PhoneVisualContext) async throws -> PhoneVisualFrame {
        if holdSnapshot { await withCheckedContinuation { continuation = $0 }; holdSnapshot = false }
        let selected = frames.isEmpty ? frame(active: clicks > 0) : frames.removeFirst()
        return PhoneVisualFrame(width: selected.width, height: selected.height, rgba: selected.rgba,
                                text: selected.text, capturedAt: ProcessInfo.processInfo.systemUptime)
    }
    func click(_ point: PhoneVisualRect, context: PhoneVisualContext, freshnessDeadline: Double, cancellation: PhoneVisualCancellation) throws {
        if forceChanged { throw PhoneVisualError.changed }
        guard cancellation.commit(deadline: expired ? ProcessInfo.processInfo.systemUptime - 1 : freshnessDeadline, {}) else {
            throw cancellation.isCancelled ? PhoneVisualError.cancelled : PhoneVisualError.deadline
        }
        clicks += 1
    }
    func release() { continuation?.resume(); continuation = nil }
    var held: Bool { continuation != nil }
}

private func SwiftContext(absent: Bool = false, start: UInt64 = 100) -> PhoneVisualContext { context(absent: absent, start: start) }

@main private struct PhoneVisualSelfCheck {
    @MainActor static func main() async throws {
        try analyzerGuards()
        try snapshotChangeGuards()
        await singleActionsAndClosure()
        await permissionAndProcessDenial()
        await cancellationAndUserReconciliation()
        await pendingPopupAndNoFalseEnd()
        try localPNGFixtures()
        print("PASS: 6 visual-control checks; synthetic providers only; no live capture, permission requests, event posts, calls or audio.")
    }
    private static func expectRejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Unsafe fixture accepted") } catch {}
    }
    private static func analyzerGuards() throws {
        let expected = try PhoneNumber("+13125550123")
        check(try PhoneVisualAnalyzer.analyze(frame(), expected: expected).observation == .confirmation)
        check(try PhoneVisualAnalyzer.analyze(frame(active: true), expected: expected).observation == .callUIVisible)
        for unsafe in [frame(number: "+442079460123"), frame(extraNumber: true), frame(unknownColor: true), frame(extraPanel: true)] {
            expectRejected { _ = try PhoneVisualAnalyzer.analyze(unsafe, expected: expected) }
        }
        let source = frame()
        let moved = PhoneVisualFrame(width: 721, height: 256, rgba: source.rgba, text: source.text, capturedAt: source.capturedAt)
        expectRejected { _ = try PhoneVisualAnalyzer.analyze(moved, expected: expected) }
    }
    private static func snapshotChangeGuards() throws {
        let expected = try PhoneNumber("+13125550123"), first = frame()
        let a = try PhoneVisualAnalyzer.analyze(first, expected: expected)
        var data = first.rgba; data[200 * 4 + 1] = 45
        let second = PhoneVisualFrame(width: first.width, height: first.height, rgba: data, text: first.text, capturedAt: first.capturedAt)
        let b = try PhoneVisualAnalyzer.analyze(second, expected: expected)
        check(!PhoneVisualAnalyzer.unchanged(first, second, firstAnalysis: a, secondAnalysis: b))
    }
    @MainActor private static func singleActionsAndClosure() async {
        let provider = FixtureVisualProvider(), controller = PhoneVisualController(provider: provider), job = UUID()
        check(await controller.warmUp()); check(!controller.report.busy)
        try! controller.prepare(jobID: job, expectedNumber: "+13125550123")
        let confirmation = await controller.confirm()
        check(confirmation.confirmationClickPosted && confirmation.observation == .callUIVisible && !confirmation.busy)
        _ = await controller.confirm(); check(await provider.clicks == 1)
        let ended = await controller.hangup()
        check(ended.hangupClickPosted && ended.observation == .hangupRequestedPanelClosed && !ended.busy)
        _ = await controller.hangup(); check(await provider.clicks == 2)
        check(!controller.reportJSON()!.contains("13125550123"))
        try! controller.prepare(jobID: UUID(), expectedNumber: "+442079460123")
        expectRejected { try controller.prepare(jobID: job, expectedNumber: "+13125550123") }
    }
    @MainActor private static func permissionAndProcessDenial() async {
        for permissions in [PhoneVisualPermissions(accessibility: false, screenCapture: true), PhoneVisualPermissions(accessibility: true, screenCapture: false)] {
            let provider = FixtureVisualProvider(); await provider.configure(permission: permissions)
            let controller = PhoneVisualController(provider: provider)
            try! controller.prepare(jobID: UUID(), expectedNumber: "+13125550123")
            let result = await controller.confirm()
            check(result.confirmationAttempted && !result.confirmationClickPosted && result.observation == .unknown)
            _ = await controller.confirm(); check(await provider.clicks == 0)
        }
        let changed = FixtureVisualProvider(); await changed.configure(changed: true)
        let controller = PhoneVisualController(provider: changed)
        try! controller.prepare(jobID: UUID(), expectedNumber: "+13125550123")
        check(!(await controller.confirm()).confirmationClickPosted)
        check(await changed.clicks == 0)
        let expired = FixtureVisualProvider(); await expired.configure(expired: true)
        let stale = PhoneVisualController(provider: expired)
        try! stale.prepare(jobID: UUID(), expectedNumber: "+13125550123")
        check(!(await stale.confirm()).confirmationClickPosted)
        check(await expired.clicks == 0)
    }
    @MainActor private static func cancellationAndUserReconciliation() async {
        let provider = FixtureVisualProvider(); await provider.configure(hold: true)
        let controller = PhoneVisualController(provider: provider), job = UUID()
        try! controller.prepare(jobID: job, expectedNumber: "+13125550123")
        let pending = Task { @MainActor in await controller.confirm() }
        for _ in 0..<1_000 {
            if await provider.held { break }; try? await Task.sleep(for: .milliseconds(1))
        }
        controller.cancel(); check(controller.report.busy)
        controller.reconcileUserReportedEnd(jobID: job)
        expectRejected { try controller.prepare(jobID: UUID(), expectedNumber: "+13125550123") }
        await provider.release(); _ = await pending.value
        check(!controller.report.busy && !controller.report.confirmationClickPosted)
        check(await provider.clicks == 0)
        check(controller.report.observation == .unknown && controller.status.contains("User reported"))
        try! controller.prepare(jobID: UUID(), expectedNumber: "+442079460123")
        let committed = FixtureVisualProvider(), second = PhoneVisualController(provider: committed)
        try! second.prepare(jobID: UUID(), expectedNumber: "+13125550123")
        _ = await second.confirm(); second.cancel()
        check(second.report.confirmationClickPosted && second.report.canHangup)
        _ = await second.hangup(); check(await committed.clicks == 2)
    }
    @MainActor private static func pendingPopupAndNoFalseEnd() async {
        let provider = FixtureVisualProvider(); await provider.configure(missingOnce: true, startupProcessFailures: 2)
        let controller = PhoneVisualController(provider: provider)
        try! controller.prepare(jobID: UUID(), expectedNumber: "+13125550123")
        check((await controller.confirm()).confirmationClickPosted)
        let changed = FixtureVisualProvider(); await changed.configure(processChangedAfterHangup: true)
        let second = PhoneVisualController(provider: changed), job = UUID()
        try! second.prepare(jobID: job, expectedNumber: "+13125550123")
        _ = await second.confirm()
        let result = await second.hangup()
        check(result.hangupClickPosted && result.observation == .unknown)
        expectRejected { try second.prepare(jobID: UUID(), expectedNumber: "+442079460123") }
        second.reconcileUserReportedEnd(jobID: job)
        try! second.prepare(jobID: UUID(), expectedNumber: "+442079460123")
        let absent = FixtureVisualProvider(); await absent.configure(missingOnce: true)
        let inspection = PhoneVisualController(provider: absent)
        try! inspection.prepare(jobID: UUID(), expectedNumber: "+13125550123")
        check((await inspection.inspect()).observation == .unknown)
    }
    private static func localPNGFixtures() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { return }
        let expected = try PhoneNumber(arguments[1])
        try PhoneVisualRaster.warmUp()
        for (index, path) in arguments.dropFirst(2).enumerated() {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  original.width == 2992, original.height == 1934,
                  let cropped = original.cropping(to: CGRect(x: 2238, y: 104, width: 722, height: 256)) else {
                throw PhoneVisualError.layout
            }
            let frame = try PhoneVisualRaster.frame(cropped, capturedAt: ProcessInfo.processInfo.systemUptime)
            if ProcessInfo.processInfo.environment["PHONE_VISUAL_FIXTURE_DEBUG"] == "1" {
                for text in frame.text {
                    let safe = PhoneProbePrivacy.label(text.value, expected: expected)
                    let line = "Fixture \(index) \(safe) confidence \(text.confidence) bounds \(text.bounds)\n"
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
            let analysis = try PhoneVisualAnalyzer.analyze(frame, expected: expected)
            check(analysis.observation == (index == 0 ? .confirmation : .callUIVisible))
        }
        print("PASS: 2 authorized local PNG/OCR regressions; images stayed in memory and no OCR content was printed.")
    }
}
