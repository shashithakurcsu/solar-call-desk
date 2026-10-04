import Foundation
import CallCore

public enum PhoneControlProbeState: String, Codable, Sendable {
    case idle, running, finished, cancelled
}

public struct PhoneControlBounds: Codable, Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
}

public struct PhoneControlChildEdge: Codable, Sendable, Equatable {
    public let attribute: String
    public let index: Int
    public let elementReference: Int
}

public struct PhoneControlElement: Codable, Sendable, Equatable {
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public var actions: [String]
    public let enabled: Bool?
    /// Only fixed control/state labels or the redacted exact-target marker.
    public var labels: [String]
    public let depth: Int
    public let windowIndex: Int
    /// Zero is window metadata; positive values identify independently matched restricted panels.
    public let panelIndex: Int
    /// Structure-only traversal location relative to its window root.
    public var childPath: [Int] = []
    public var childCount: Int? = nil
    /// Observed AX owner only; this does not authorize reading an embedded element's content.
    public var elementProcessIdentifier: Int32? = nil
    public var elementReference: Int? = nil
    public var childAttributePath: [String] = []
    public var childEdges: [PhoneControlChildEdge] = []
    public var navigationChildCounts: [String: Int] = [:]
    public var supportedAttributes: [String] = []
    public var supportedAttributeCount: Int? = nil
    public var phoneOwnerVerified: Bool = false
    public var bounds: PhoneControlBounds? = nil
}

public struct PhoneControlCandidateReport: Codable, Sendable, Equatable {
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public var windowCount: Int = 0
    public var elements: [PhoneControlElement] = []
    public var structureOnly: Bool = false
    public var embeddedPhoneInspection: Bool = false
}

public struct PhoneControlReport: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case phoneStatus, readOnly, metadataOnly, permissionGranted, targetMatched, candidates
        case operations, visitedElements, truncated, cancelled, errors, elapsedSeconds
        case operationLimit, elementLimit, depthLimit, messagingTimeoutSeconds, scanBudgetSeconds
    }
    public let phoneStatus: String = "unknown"
    public let readOnly: Bool = true
    public let metadataOnly: Bool
    public let permissionGranted: Bool
    public var targetMatched: Bool = false
    public var candidates: [PhoneControlCandidateReport] = []
    public var operations: Int = 0
    public var visitedElements: Int = 0
    public var truncated: Bool = false
    public var cancelled: Bool = false
    public var errors: [String] = []
    public var elapsedSeconds: Double = 0
    public let operationLimit: Int = 300
    public let elementLimit: Int = 128
    public let depthLimit: Int = 8
    public let messagingTimeoutSeconds: Double = 0.15
    public let scanBudgetSeconds: Double = 2

    public init(metadataOnly: Bool, permissionGranted: Bool) {
        self.metadataOnly = metadataOnly
        self.permissionGranted = permissionGranted
    }
}

struct PhoneProbeCandidate: Sendable, Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    var bundlePath: String? = nil
    var launchTime: Double? = nil
    var processStart: PhoneProbeProcessStart? = nil
    var isMainPhone: Bool { bundleIdentifier == "com.apple.mobilephone" }
    var isStructureOnly: Bool { bundleIdentifier == "com.apple.notificationcenterui" }
    var isEmbeddedPhoneOwner: Bool {
        ["com.apple.facetime.NotificationViewBridgeService", "com.apple.FaceTime.FaceTimeNotificationExtension"].contains(bundleIdentifier)
    }
}

enum PhoneProbePrivacy {
    static let bundles: Set<String> = [
        "com.apple.mobilephone", "com.apple.facetime.NotificationService",
        "com.apple.facetime.NotificationViewBridgeService",
        "com.apple.FaceTime.FaceTimeNotificationExtension", "com.apple.notificationcenterui"
    ]
    static let labels: Set<String> = [
        "Call", "Cancel", "End Call", "Hang Up", "Accept", "Decline", "Answer",
        "Audio", "Video", "Mute", "Unmute", "Speaker", "Connecting", "Calling",
        "Ringing", "Incoming Call", "Outgoing Call", "Call Ended", "FaceTime Audio",
        "FaceTime Video", "Close", "Continue", "Click to Call", "End", "Connected"
    ]
    static let identifiers: Set<String> = [
        "callButton", "CallButton", "endCallButton", "EndCallButton", "hangUpButton",
        "acceptButton", "declineButton", "answerButton", "cancelButton", "muteButton",
        "unmuteButton", "audioCallButton", "videoCallButton", "callStatus", "callPanel"
    ]
    static let actions: Set<String> = ["AXPress", "AXCancel", "AXShowMenu", "AXRaise", "AXConfirm"]
    static let attributeNames: Set<String> = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXIdentifier", "AXTitle", "AXValue", "AXDescription",
        "AXHelp", "AXEnabled", "AXChildren", "AXChildrenInNavigationOrder", "AXContents", "AXVisibleChildren",
        "AXParent", "AXPosition", "AXSize", "AXSelected", "AXFocused", "AXFrame", "AXTopLevelUIElement",
        "AXWindow", "AXWindows", "AXSheets", "AXFullScreen", "AXMinimized", "AXMain", "AXCloseButton",
        "AXCancelButton", "AXDefaultButton", "AXURL", "AXApplication", "AXElementBusy", "AXCustomContent"
    ]
    static let structures: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDialog", "AXSystemDialog", "AXStandardWindow",
        "AXFloatingWindow", "AXSystemFloatingWindow", "AXGroup", "AXSplitGroup", "AXButton",
        "AXStaticText", "AXTextField", "AXTextArea", "AXImage", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuItem", "AXToolbar", "AXScrollArea",
        "AXScrollBar", "AXTable", "AXOutline", "AXList", "AXRow", "AXCell", "AXColumn",
        "AXUnknown", "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
        "AXLayoutArea", "AXLayoutItem", "AXProgressIndicator", "AXBusyIndicator", "AXSeparator"
    ]

    static func structure(_ value: String?) -> String? {
        guard let value else { return nil }
        return structures.contains(value) ? value : "[redacted]"
    }
    static func identifier(_ value: String?) -> String? {
        guard let value else { return nil }
        if bundles.contains(value) { return value }
        if identifiers.contains(value) { return value }
        // Retain original identifiers only when every component is generic UI vocabulary.
        // Unknown names, number-bearing IDs, tokens and arbitrary free text stay redacted.
        guard value.count <= 96, !value.isEmpty,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) })
        else { return "[redacted]" }
        var words: [String] = [], word = ""
        for character in value {
            if ".-_".contains(character) {
                if !word.isEmpty { words.append(word.lowercased()); word = "" }
            } else if character.isUppercase, !word.isEmpty, word.last?.isLowercase == true {
                words.append(word.lowercased()); word = String(character)
            } else { word.append(character) }
        }
        if !word.isEmpty { words.append(word.lowercased()) }
        let vocabulary: Set<String> = ["ax", "com", "apple", "facetime", "phone", "notification", "view", "bridge", "service",
            "call", "button", "end", "hang", "up", "accept", "decline", "answer", "cancel", "mute", "unmute",
            "audio", "video", "status", "panel", "confirm", "confirmation", "green", "red", "close", "continue",
            "incoming", "outgoing", "connecting", "connected", "ringing", "label", "text", "group", "container",
            "center", "content", "list", "scroll", "area", "item", "window", "root", "stack", "hosting", "host",
            "extension", "kit", "platter", "banner", "widget", "collection"]
        let controls: Set<String> = ["button", "status", "panel", "label", "group", "container", "window", "view", "list", "area", "item", "root", "stack", "platter", "banner", "widget", "collection"]
        return !words.isEmpty && words.allSatisfy(vocabulary.contains) && !controls.isDisjoint(with: words)
            ? value : "[redacted]"
    }
    static func label(_ value: String, expected: PhoneNumber?) -> String {
        if let expected, matches(value, expected: expected) { return "[target number]" }
        return labels.contains(value) ? value : "[redacted]"
    }
    static func matches(_ displayed: String, expected: PhoneNumber) -> Bool {
        // A whole field only: no substring, Unicode digit, extension, prose or contact-name binding.
        let value = displayed.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        guard !value.isEmpty else { return false }
        let separators: Set<Unicode.Scalar> = [" ", "(", ")", "-", "."]
        guard value.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || $0 == "+" || separators.contains($0)
        }) else { return false }
        let compact = String(String.UnicodeScalarView(value.unicodeScalars.filter { !separators.contains($0) }))
        guard !compact.dropFirst(compact.hasPrefix("+") ? 1 : 0).contains("+") else { return false }
        let digits = compact.hasPrefix("+") ? String(compact.dropFirst()) : compact
        let expectedDigits = String(expected.normalized.dropFirst())
        if digits == expectedDigits { return true }
        return !compact.hasPrefix("+") && expectedDigits.count == 11 && expectedDigits.hasPrefix("1")
            && digits.count == 10 && digits == String(expectedDigits.dropFirst())
    }

    static func trustedPath(bundle: String, path: String) -> Bool {
        guard bundles.contains(bundle), !path.contains("/../"), !path.contains("/./") else { return false }
        // Exact bundle/path pairs observed through public NSWorkspace metadata.
        // These paths identify AX owners only; no private framework is loaded or called.
        let paths = [
            "com.apple.mobilephone": "/System/Applications/Phone.app",
            "com.apple.facetime.NotificationService": "/System/Library/PrivateFrameworks/FaceTimeNotification.framework/Versions/A/XPCServices/FaceTimeNotificationService.xpc",
            "com.apple.facetime.NotificationViewBridgeService": "/System/Library/PrivateFrameworks/FaceTimeNotificationViewBridge.framework/Versions/A/XPCServices/FaceTimeNotificationViewBridgeService.xpc",
            "com.apple.FaceTime.FaceTimeNotificationExtension": "/System/Library/ExtensionKit/Extensions/FaceTimeNotificationExtension.appex",
            "com.apple.notificationcenterui": "/System/Library/CoreServices/NotificationCenter.app"
        ]
        return paths[bundle] == path
    }
}

/// Cancellation is shared with the serial scanner; no AX references cross this boundary.
final class PhoneProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.withLock { stopped = true } }
    var isCancelled: Bool { lock.withLock { stopped } }
}

struct PhoneProbeBudget {
    let start: Double
    let now: () -> Double
    let cancellation: PhoneProbeCancellation
    var operations = 0
    var nodes = 0
    var truncated = false
    init(cancellation: PhoneProbeCancellation, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.cancellation = cancellation; self.now = now; self.start = now()
    }
    mutating func operation() -> Bool {
        guard !cancellation.isCancelled else { return false }
        guard operations < 300, now() - start < 2 else { truncated = true; return false }
        operations += 1; return true
    }
    mutating func visit(depth: Int) -> Bool {
        guard !cancellation.isCancelled else { return false }
        guard depth <= 8, nodes < 128, now() - start < 2 else { truncated = true; return false }
        nodes += 1; return true
    }
}
