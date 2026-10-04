import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import Foundation

/// Only local primitives escape synchronous AX work. Screenshot pixels stay in memory.
actor PhoneVisualLiveProvider: PhoneVisualProvider {
    private var warmed = false
    func warmUp() throws {
        guard !warmed else { return }
        try PhoneVisualRaster.warmUp(); warmed = true
    }
    func permissions() async -> PhoneVisualPermissions {
        PhoneVisualPermissions(accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess())
    }
    private func session(_ identities: [PhoneVisualIdentity]) async throws {
        guard (await permissions()).granted else { throw PhoneVisualError.permission }
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard console?[kCGSessionOnConsoleKey as String] as? Bool == true,
              console?[kCGSessionLoginDoneKey as String] as? Bool == true,
              CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { throw PhoneVisualError.session }
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let phone = identities.first(where: { $0.candidate.isMainPhone }), front == phone.candidate.processIdentifier else {
            throw PhoneVisualError.session
        }
        for identity in identities {
            let candidate = identity.candidate
            guard let current = NSRunningApplication(processIdentifier: candidate.processIdentifier), !current.isTerminated,
                  current.bundleIdentifier == candidate.bundleIdentifier,
                  current.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == candidate.bundlePath,
                  PhoneProbeProcessMetadata.startTime(pid: candidate.processIdentifier) == identity.start else {
                throw PhoneVisualError.process
            }
        }
    }
    private func windows(hostPID: Int32) -> [(UInt32, PhoneVisualRect)] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 == hostPID,
                  window[kCGWindowLayer as String] as? Int == 21,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            return (id, PhoneVisualRect(x: x, y: y, width: width, height: height))
        }
    }
    func context() async throws -> PhoneVisualContext {
        guard (await permissions()).granted else { throw PhoneVisualError.permission }
        let identities: [PhoneVisualIdentity] = await MainActor.run {
            let required: Set<String> = ["com.apple.mobilephone", "com.apple.notificationcenterui",
                                        "com.apple.facetime.NotificationViewBridgeService", "com.apple.FaceTime.FaceTimeNotificationExtension"]
            return NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, let bundle = app.bundleIdentifier, required.contains(bundle),
                      let path = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path,
                      PhoneProbePrivacy.trustedPath(bundle: bundle, path: path),
                      let start = PhoneProbeProcessMetadata.startTime(pid: app.processIdentifier) else { return nil }
                let candidate = PhoneProbeCandidate(bundleIdentifier: bundle, processIdentifier: app.processIdentifier,
                                                    bundlePath: path, launchTime: app.launchDate?.timeIntervalSince1970, processStart: start)
                return PhoneVisualIdentity(candidate: candidate, start: start)
            }.sorted { $0.candidate.bundleIdentifier < $1.candidate.bundleIdentifier }
        }
        guard identities.count == 4, Set(identities.map { $0.candidate.bundleIdentifier }).count == 4,
              let host = identities.first(where: { $0.candidate.isStructureOnly }),
              let bridge = identities.first(where: { $0.candidate.bundleIdentifier == "com.apple.facetime.NotificationViewBridgeService" }),
              let extensionOwner = identities.first(where: { $0.candidate.bundleIdentifier == "com.apple.FaceTime.FaceTimeNotificationExtension" })
        else { throw PhoneVisualError.process }
        try await session(identities)
        let current = windows(hostPID: host.candidate.processIdentifier)
        guard current.count <= 1 else { throw PhoneVisualError.panel }
        if current.isEmpty {
            return PhoneVisualContext(identities: identities, windowID: nil, hostPID: host.candidate.processIdentifier,
                                      windowBounds: nil, bridgeBounds: nil, absent: true)
        }
        guard current[0].1 == PhoneVisualRect(x: 0, y: 0, width: 1496, height: 967) else { throw PhoneVisualError.layout }
        // Existing bounded read-only AX discovery establishes the independently verified embedded owners.
        let discovery = PhoneProbeScanner.live(candidates: identities.map(\.candidate), expected: nil, cancellation: PhoneProbeCancellation())
        guard !discovery.truncated, let nc = discovery.candidates.first(where: { $0.processIdentifier == host.candidate.processIdentifier }) else {
            throw PhoneVisualError.panel
        }
        let bridges = nc.elements.filter { $0.phoneOwnerVerified && $0.elementProcessIdentifier == bridge.candidate.processIdentifier && $0.bounds != nil }
        guard bridges.count == 1, let bounds = bridges[0].bounds,
              bounds == PhoneControlBounds(x: 1119, y: 52, width: 361, height: 600),
              nc.elements.contains(where: { $0.phoneOwnerVerified && $0.elementProcessIdentifier == extensionOwner.candidate.processIdentifier && $0.childPath.starts(with: bridges[0].childPath) })
        else { throw PhoneVisualError.panel }
        try await session(identities)
        guard windows(hostPID: host.candidate.processIdentifier).first?.0 == current[0].0 else { throw PhoneVisualError.changed }
        return PhoneVisualContext(identities: identities, windowID: current[0].0, hostPID: host.candidate.processIdentifier,
                                  windowBounds: current[0].1,
                                  bridgeBounds: PhoneVisualRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height), absent: false)
    }
    func snapshot(_ context: PhoneVisualContext) async throws -> PhoneVisualFrame {
        try await session(context.identities)
        guard !context.absent, let id = context.windowID, let bridge = context.bridgeBounds,
              let current = windows(hostPID: context.hostPID).only,
              current.0 == id, current.1 == context.windowBounds else { throw PhoneVisualError.changed }
        let available = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = available.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == context.hostPID }) else {
            throw PhoneVisualError.panel
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: bridge.x, y: bridge.y, width: PhoneVisualAnalyzer.captureWidth, height: PhoneVisualAnalyzer.captureHeight)
        configuration.width = 722; configuration.height = 256; configuration.showsCursor = false
        // ScreenCaptureKit's documented default background is clear.
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try await session(context.identities)
        guard ProcessInfo.processInfo.systemUptime - capturedAt < 3 else { throw PhoneVisualError.deadline }
        return try PhoneVisualRaster.frame(image, capturedAt: capturedAt)
    }
    func click(_ button: PhoneVisualRect, context: PhoneVisualContext, freshnessDeadline: Double, cancellation: PhoneVisualCancellation) async throws {
        guard !cancellation.isCancelled, try await self.context() == context, let bridge = context.bridgeBounds else {
            throw PhoneVisualError.changed
        }
        let center = button.center
        let point = CGPoint(x: bridge.x + center.0, y: bridge.y + center.1)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw PhoneVisualError.panel
        }
        guard cancellation.commit(deadline: freshnessDeadline, { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }) else {
            throw cancellation.isCancelled ? PhoneVisualError.cancelled : PhoneVisualError.deadline
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
