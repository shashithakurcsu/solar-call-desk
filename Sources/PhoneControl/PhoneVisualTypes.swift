import Foundation
import CallCore

public enum PhoneVisualObservation: String, Codable, Sendable {
    case confirmation
    case callUIVisible = "call_ui_visible"
    case hangupRequestedPanelClosed = "hangup_requested_panel_closed"
    case unknown
}

public struct PhoneVisualPermissions: Codable, Sendable, Equatable {
    public let accessibility: Bool
    public let screenCapture: Bool
    public var granted: Bool { accessibility && screenCapture }
    public init(accessibility: Bool, screenCapture: Bool) {
        self.accessibility = accessibility; self.screenCapture = screenCapture
    }
}

public struct PhoneVisualReport: Codable, Sendable, Equatable {
    public var observation: PhoneVisualObservation = .unknown
    public var status: String = "Visual Phone control has not been prepared."
    public var jobID: UUID?
    public var confirmationAttempted = false
    public var confirmationClickPosted = false
    public var hangupAttempted = false
    public var hangupClickPosted = false
    public var canConfirm = false
    public var canHangup = false
    public var busy = false
    public let carrierStatus = "unknown"
    private enum CodingKeys: String, CodingKey {
        case observation, status, jobID, confirmationAttempted, confirmationClickPosted
        case hangupAttempted, hangupClickPosted, canConfirm, canHangup, busy, carrierStatus
    }
    public init() {}
}

public enum PhoneVisualError: Error, LocalizedError, Sendable {
    case invalidNumber, busy, activeJob, jobMismatch, permission, session, process, panel, layout, changed, cancelled, deadline
    public var errorDescription: String? {
        switch self {
        case .invalidNumber: "Use a canonical international number: + followed by 8–15 digits."
        case .busy: "A visual Phone operation is already running."
        case .activeJob: "The existing job still requires a reviewed end check."
        case .jobMismatch: "This job cannot be rebound to another target."
        case .permission: "Existing Accessibility and screen-capture permission are required."
        case .session: "Use an awake logged-in console session with Phone frontmost."
        case .process: "The verified Phone process identity changed or is unavailable."
        case .panel: "A unique verified Phone notification panel was not established."
        case .layout: "The popup does not match the supported reviewed Phone layout."
        case .changed: "The fresh Phone popup changed before the action; no retry is permitted for this job."
        case .cancelled: "Visual Phone operation cancelled."
        case .deadline: "Visual Phone verification exceeded its freshness budget."
        }
    }
}

struct PhoneVisualRect: Codable, Sendable, Equatable {
    let x: Double, y: Double, width: Double, height: Double
    var center: (Double, Double) { (x + width / 2, y + height / 2) }
}

struct PhoneVisualIdentity: Sendable, Equatable {
    let candidate: PhoneProbeCandidate
    let start: PhoneProbeProcessStart
}

struct PhoneVisualContext: Sendable, Equatable {
    let identities: [PhoneVisualIdentity]
    let windowID: UInt32?
    let hostPID: Int32
    let windowBounds: PhoneVisualRect?
    let bridgeBounds: PhoneVisualRect?
    let absent: Bool
}

struct PhoneVisualText: Sendable {
    let value: String
    let confidence: Float
    let bounds: PhoneVisualRect
}

struct PhoneVisualFrame: Sendable {
    let width: Int
    let height: Int
    let rgba: Data
    let text: [PhoneVisualText]
    let capturedAt: Double
}

struct PhoneVisualAnalysis: Sendable {
    let observation: PhoneVisualObservation
    let button: PhoneVisualRect
    let numberBounds: PhoneVisualRect
}

protocol PhoneVisualProvider: Sendable {
    func warmUp() async throws
    func permissions() async -> PhoneVisualPermissions
    func context() async throws -> PhoneVisualContext
    func snapshot(_ context: PhoneVisualContext) async throws -> PhoneVisualFrame
    func click(_ point: PhoneVisualRect, context: PhoneVisualContext, freshnessDeadline: Double, cancellation: PhoneVisualCancellation) async throws
}
extension PhoneVisualProvider {
    func warmUp() async throws {}
}

final class PhoneVisualCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
    /// Cancellation and the single event pair have a defined commit order.
    func commit(deadline: Double = .infinity, _ action: () -> Void) -> Bool {
        lock.withLock {
            guard !stopped, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            action(); return true
        }
    }
}

enum PhoneVisualAnalyzer {
    // Only the observed macOS layout is supported. Coordinates are relative to the independently
    // verified bridge frame, never supplied by a user or inferred from arbitrary desktop content.
    static let captureWidth = 361.0
    static let captureHeight = 128.0
    static func analyze(_ frame: PhoneVisualFrame, expected: PhoneNumber) throws -> PhoneVisualAnalysis {
        guard frame.width == 722, frame.height == 256, frame.rgba.count == frame.width * frame.height * 4,
              frame.text.count <= 32 else { throw PhoneVisualError.layout }
        _ = try PhoneVisualRaster.pill(frame.rgba)
        let numbers = frame.text.filter { (try? PhoneNumber($0.value)) != nil }
        guard numbers.count == 1, let number = numbers.first, number.confidence >= 0.9,
              (try? PhoneNumber(number.value).normalized) == expected.normalized,
              number.bounds.x >= 35, number.bounds.x <= 110, number.bounds.y >= 0, number.bounds.y <= 32,
              number.bounds.width >= 80, number.bounds.width <= 240, number.bounds.height >= 6, number.bounds.height <= 25
        else { throw PhoneVisualError.panel }
        let greens = components(frame, green: true), reds = components(frame, green: false)
        let callLabels = frame.text.filter { $0.confidence >= 0.9 && $0.value.caseInsensitiveCompare("Click to Call") == .orderedSame }
        if callLabels.count == 1, greens.count == 1, reds.isEmpty {
            let button = greens[0], center = button.center
            guard (50...110).contains(button.width), (18...40).contains(button.height),
                  (271...356).contains(center.0), (3...43).contains(center.1),
                  (18...65).contains(callLabels[0].bounds.y) else { throw PhoneVisualError.layout }
            return PhoneVisualAnalysis(observation: .confirmation, button: button, numberBounds: number.bounds)
        }
        if callLabels.isEmpty, reds.count == 1, greens.isEmpty {
            let button = reds[0], center = button.center
            guard (25...60).contains(button.width), (25...60).contains(button.height),
                  (311...356).contains(center.0), (58...113).contains(center.1) else { throw PhoneVisualError.layout }
            return PhoneVisualAnalysis(observation: .callUIVisible, button: button, numberBounds: number.bounds)
        }
        throw PhoneVisualError.layout
    }

    private static func components(_ frame: PhoneVisualFrame, green: Bool) -> [PhoneVisualRect] {
        let bytes = [UInt8](frame.rgba), width = frame.width, height = frame.height
        var marked = [Bool](repeating: false, count: width * height)
        func matches(_ offset: Int) -> Bool {
            let index = offset * 4
            let r = Double(bytes[index]) / 255, g = Double(bytes[index + 1]) / 255, b = Double(bytes[index + 2]) / 255
            guard bytes[index + 3] > 204 else { return false }
            return green ? g > 0.72 && g > r * 1.4 && g > b * 1.3 && r < 0.65
                : r > 0.7 && r > g * 1.4 && r > b * 1.4 && g < 0.65 && b < 0.65
        }
        var results: [PhoneVisualRect] = []
        for offset in 0..<(width * height) where !marked[offset] && matches(offset) {
            var stack = [offset], cursor = 0, left = width, right = 0, top = height, bottom = 0
            marked[offset] = true
            while cursor < stack.count {
                let current = stack[cursor]; cursor += 1
                let x = current % width, y = current / width
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                for next in [x > 0 ? current - 1 : -1, x + 1 < width ? current + 1 : -1,
                             y > 0 ? current - width : -1, y + 1 < height ? current + width : -1]
                    where next >= 0 && !marked[next] && matches(next) {
                    marked[next] = true; stack.append(next)
                }
            }
            if stack.count > 500 {
                results.append(PhoneVisualRect(x: Double(left) / 2, y: Double(top) / 2,
                                               width: Double(right - left + 1) / 2, height: Double(bottom - top + 1) / 2))
            }
        }
        return results
    }

    static func unchanged(_ first: PhoneVisualFrame, _ second: PhoneVisualFrame,
                          firstAnalysis: PhoneVisualAnalysis, secondAnalysis: PhoneVisualAnalysis) -> Bool {
        guard first.width == second.width, first.height == second.height,
              firstAnalysis.observation == secondAnalysis.observation,
              firstAnalysis.button == secondAnalysis.button, firstAnalysis.numberBounds == secondAnalysis.numberBounds else { return false }
        if firstAnalysis.observation == .confirmation { return first.rgba == second.rgba }
        return samePixels(first, second, rectangle: firstAnalysis.numberBounds)
            && samePixels(first, second, rectangle: firstAnalysis.button)
    }
    private static func samePixels(_ a: PhoneVisualFrame, _ b: PhoneVisualFrame, rectangle: PhoneVisualRect) -> Bool {
        let left = max(0, Int(rectangle.x * 2)), top = max(0, Int(rectangle.y * 2))
        let right = min(a.width, Int((rectangle.x + rectangle.width) * 2 + 1))
        let bottom = min(a.height, Int((rectangle.y + rectangle.height) * 2 + 1))
        guard right > left, bottom > top, a.rgba.count == b.rgba.count else { return false }
        for row in top..<bottom {
            let low = (row * a.width + left) * 4, high = (row * a.width + right) * 4
            if a.rgba[low..<high] != b.rgba[low..<high] { return false }
        }
        return true
    }
}
