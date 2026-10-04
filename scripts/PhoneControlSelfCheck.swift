import Foundation
import CallCore
@testable import PhoneControl

private struct FixtureNode {
    var strings: [String: String] = [:]
    var children: [String: [Int]] = [:]
    var actions: [String] = []
    var enabled = true
    var processIdentifier: Int32 = 772
    var advertised: [String] = []
    var geometry: [String: [Double]] = [:]
}

private final class FixtureProvider: PhoneProbeProvider {
    var nodes: [Int: FixtureNode]
    var reads: [(Int, String)] = []
    var childLimits: [Int] = []
    var timeouts: Set<Int> = []
    var calls = 0
    var afterCall: (() -> Void)?
    var currentIdentities: [Int32: PhoneProbeCandidate] = [:]
    init(_ nodes: [Int: FixtureNode]) { self.nodes = nodes }
    private func record(_ element: Int, _ attribute: String) {
        calls += 1; reads.append((element, attribute)); afterCall?()
    }
    func application(pid: Int32) -> Int { record(0, "application"); return 0 }
    func timeout(_ element: Int) -> Int32 { record(element, "timeout"); timeouts.insert(element); return 0 }
    func string(_ element: Int, attribute: String) -> (String?, Int32) {
        precondition(timeouts.contains(element)); record(element, attribute)
        return (nodes[element]?.strings[attribute], 0)
    }
    func bool(_ element: Int, attribute: String) -> (Bool?, Int32) {
        precondition(timeouts.contains(element)); record(element, attribute); return (nodes[element]?.enabled, 0)
    }
    func count(_ element: Int, attribute: String) -> (Int?, Int32) {
        precondition(timeouts.contains(element)); record(element, attribute)
        return (nodes[element]?.children[attribute]?.count ?? 0, 0)
    }
    func children(_ element: Int, attribute: String, limit: Int) -> ([Int], Int32) {
        precondition(timeouts.contains(element)); record(element, attribute); childLimits.append(limit)
        return (Array((nodes[element]?.children[attribute] ?? []).prefix(limit)), 0)
    }
    func actions(_ element: Int) -> ([String], Int32) {
        precondition(timeouts.contains(element)); record(element, "actions"); return (nodes[element]?.actions ?? [], 0)
    }
    func processIdentifier(_ element: Int) -> (Int32?, Int32) {
        precondition(timeouts.contains(element)); record(element, "pid")
        return (nodes[element]?.processIdentifier, 0)
    }
    func attributes(_ element: Int) -> ([String], Int, Int32) {
        precondition(timeouts.contains(element)); record(element, "attributes")
        let values = nodes[element]?.advertised ?? []
        return (Array(values.prefix(64)), values.count, 0)
    }
    func isCurrentCandidate(_ candidate: PhoneProbeCandidate) -> Bool {
        record(Int(candidate.processIdentifier), "identity")
        return currentIdentities[candidate.processIdentifier] == candidate
    }
    func geometry(_ element: Int, attribute: String) -> ((Double, Double)?, Int32) {
        precondition(timeouts.contains(element)); record(element, attribute)
        guard let values = nodes[element]?.geometry[attribute], values.count == 2 else { return (nil, 0) }
        return ((values[0], values[1]), 0)
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let release = DispatchSemaphore(value: 0)
    var calls: Int { lock.withLock { count } }
    func enter() -> Int { lock.withLock { count += 1; return count } }
}

@main private struct PhoneControlSelfCheck {
    private static let helper = PhoneProbeCandidate(bundleIdentifier: "com.apple.facetime.NotificationService", processIdentifier: 77)
    private static let phone = PhoneProbeCandidate(bundleIdentifier: "com.apple.mobilephone", processIdentifier: 78)
    private static let notificationCenter = PhoneProbeCandidate(bundleIdentifier: "com.apple.notificationcenterui", processIdentifier: 772)
    private static func base() -> [Int: FixtureNode] {
        [0: FixtureNode(children: ["AXWindows": [1]]),
         1: FixtureNode(strings: ["AXRole": "AXWindow", "AXSubrole": "AXStandardWindow", "AXTitle": "Private Contact"], children: ["AXChildren": [2, 3, 4]]),
         2: FixtureNode(strings: ["AXRole": "AXStaticText", "AXValue": "+1 (312) 555-0123", "AXDescription": "Private Contact", "AXIdentifier": "secret-token-do-not-output"]),
         3: FixtureNode(strings: ["AXRole": "AXButton", "AXTitle": "End Call", "AXIdentifier": "endCallButton"], actions: ["AXPress", "private-secret-action"]),
         4: FixtureNode(strings: ["AXRole": "AXList", "AXValue": "Private Contact"], children: ["AXChildren": [5]]),
         5: FixtureNode(strings: ["AXRole": "AXStaticText", "AXValue": "Private History"]) ]
    }
    static func main() async throws {
        try privacyAndNumberMatch()
        try metadataOnlyDoesNotReadText()
        try phoneSkipsOrdinaryWindowsAndScansOnlyExplicitSheets()
        try helperSanitizesAndStopsAtLists()
        try detailsRequireExactPanelMatch()
        try notificationCenterNeverReadsContent()
        try notificationCenterScopeRemainsBounded()
        try embeddedOwnerDiscoveryIsScopedAndBounded()
        try embeddedOwnerIdentityCannotBeReusedOrInherited()
        try processStartIdentityAllowsHelpersWithoutLaunchDate()
        try limitsAndCycleHandling()
        deadlineOperationNodeAndCancellationBudgets()
        try cancellationStopsSubsequentReads()
        await probeLifecycle()
        print("PASS: 14 Phone-control checks; synthetic providers only, no real AX, Phone, permission, mic or network operations.")
    }
    private static func privacyAndNumberMatch() throws {
        let number = try PhoneNumber("+1 312 555 0123")
        for value in ["+1 (312) 555-0123", "13125550123", "3125550123"] {
            precondition(PhoneProbePrivacy.matches(value, expected: number))
        }
        for value in ["Private Contact", "Call +13125550123", "+131255501230", "+3125550123", "+13125550123 ext 2", "１３１２５５５０１２３", "+13125550123\n", "\t13125550123"] {
            precondition(!PhoneProbePrivacy.matches(value, expected: number))
        }
        let foreign = try PhoneNumber("+44 20 7946 0123")
        precondition(!PhoneProbePrivacy.matches("2071234567", expected: foreign))
        precondition(PhoneProbePrivacy.label("Private Contact", expected: number) == "[redacted]")
        precondition(PhoneProbePrivacy.identifier("callContactSecret") == "[redacted]")
        precondition(PhoneProbePrivacy.identifier("greenConfirmationButton") == "greenConfirmationButton")
        precondition(PhoneProbePrivacy.identifier("callButton13125550123") == "[redacted]")
        precondition(PhoneProbePrivacy.structure("AXPrivateContact") == "[redacted]")
        precondition(PhoneProbePrivacy.trustedPath(bundle: phone.bundleIdentifier, path: "/System/Applications/Phone.app"))
        precondition(!PhoneProbePrivacy.trustedPath(bundle: phone.bundleIdentifier, path: "/Applications/Phone.app"))
        precondition(!PhoneProbePrivacy.trustedPath(bundle: "com.apple.fake", path: "/System/Applications/Phone.app"))
        precondition(PhoneProbePrivacy.trustedPath(bundle: notificationCenter.bundleIdentifier, path: "/System/Library/CoreServices/NotificationCenter.app"))
        precondition(!PhoneProbePrivacy.trustedPath(bundle: notificationCenter.bundleIdentifier, path: "/Applications/NotificationCenter.app"))
    }
    private static func metadataOnlyDoesNotReadText() throws {
        let provider = FixtureProvider(base())
        var scanner = PhoneProbeScanner(provider: provider, expected: nil, cancellation: PhoneProbeCancellation())
        let result = scanner.scan([helper, phone])
        precondition(result.metadataOnly && !result.targetMatched && result.phoneStatus == "unknown")
        precondition(provider.reads.allSatisfy { ["application", "timeout", "AXWindows", "AXRole", "AXSubrole"].contains($0.1) })
        precondition(result.candidates.allSatisfy { $0.windowCount == 1 })
    }
    private static func phoneSkipsOrdinaryWindowsAndScansOnlyExplicitSheets() throws {
        let number = try PhoneNumber("+13125550123")
        let provider = FixtureProvider(base())
        var scanner = PhoneProbeScanner(provider: provider, expected: number, cancellation: PhoneProbeCancellation())
        precondition(!scanner.scan([phone]).targetMatched)
        precondition(!provider.reads.contains { $0.0 == 2 || $0.1 == "AXTitle" })
        var nodes = base()
        nodes[1]?.children["AXSheets"] = [6]
        nodes[6] = FixtureNode(strings: ["AXRole": "AXSheet"], children: ["AXChildren": [2, 3]])
        let sheetProvider = FixtureProvider(nodes)
        var sheetScanner = PhoneProbeScanner(provider: sheetProvider, expected: number, cancellation: PhoneProbeCancellation())
        precondition(sheetScanner.scan([phone]).targetMatched)
        precondition(!sheetProvider.reads.contains { $0.0 == 1 && $0.1 == "AXChildren" })
        // A main-app dialog window is an explicitly permitted subtree.
        nodes[1]?.strings["AXSubrole"] = "AXDialog"
        let dialogProvider = FixtureProvider(nodes)
        var dialogScanner = PhoneProbeScanner(provider: dialogProvider, expected: number, cancellation: PhoneProbeCancellation())
        precondition(dialogScanner.scan([phone]).targetMatched)
        nodes[1]?.strings["AXRole"] = "AXDialog"
        nodes[1]?.strings.removeValue(forKey: "AXSubrole")
        var roleDialogScanner = PhoneProbeScanner(provider: FixtureProvider(nodes), expected: number, cancellation: PhoneProbeCancellation())
        precondition(roleDialogScanner.scan([phone]).targetMatched)
    }
    private static func helperSanitizesAndStopsAtLists() throws {
        let provider = FixtureProvider(base())
        var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let result = scanner.scan([helper])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        precondition(result.targetMatched && result.phoneStatus == "unknown" && result.readOnly)
        for secret in ["Private Contact", "Private History", "1312", "555", "secret-token", "private-secret-action"] {
            precondition(!encoded.contains(secret))
        }
        precondition(encoded.contains("endCallButton") && encoded.contains("End Call") && encoded.contains("[target number]"))
        precondition(!provider.reads.contains { $0.0 == 5 || ($0.0 == 4 && $0.1 == "AXChildren") })
        let decoded = try JSONDecoder().decode(PhoneControlReport.self, from: JSONEncoder().encode(result))
        precondition(decoded == result)
    }
    private static func detailsRequireExactPanelMatch() throws {
        let expected = try PhoneNumber("+13125550123")
        var scanner = PhoneProbeScanner(provider: FixtureProvider(base()), expected: try PhoneNumber("+442079460123"), cancellation: PhoneProbeCancellation())
        let unmatched = scanner.scan([helper])
        precondition(!unmatched.targetMatched)
        precondition(unmatched.candidates[0].elements.allSatisfy { $0.labels.isEmpty && $0.actions.isEmpty && $0.identifier == nil && $0.enabled == nil })
        var nodes = base()
        nodes[0]?.children["AXWindows"] = [1, 9]
        nodes[9] = FixtureNode(strings: ["AXRole": "AXWindow"], children: ["AXChildren": [10]])
        nodes[10] = FixtureNode(strings: ["AXRole": "AXButton", "AXTitle": "Click to Call", "AXIdentifier": "greenConfirmationButton"], actions: ["AXPress"])
        var windowScanner = PhoneProbeScanner(provider: FixtureProvider(nodes), expected: expected, cancellation: PhoneProbeCancellation())
        let report = windowScanner.scan([helper])
        precondition(report.targetMatched)
        let otherWindow = report.candidates[0].elements.filter { $0.windowIndex == 1 }
        precondition(otherWindow.count == 2 && otherWindow.allSatisfy { $0.labels.isEmpty && $0.actions.isEmpty && $0.identifier == nil })
        // Separate sheets in the same Phone window must not share a target binding either.
        nodes[1]?.children["AXSheets"] = [6, 7]
        nodes[6] = FixtureNode(strings: ["AXRole": "AXSheet"], children: ["AXChildren": [2]])
        nodes[7] = FixtureNode(strings: ["AXRole": "AXSheet"], children: ["AXChildren": [10]])
        var sheetScanner = PhoneProbeScanner(provider: FixtureProvider(nodes), expected: expected, cancellation: PhoneProbeCancellation())
        let sheetReport = sheetScanner.scan([phone])
        let otherPanel = sheetReport.candidates[0].elements.filter { $0.windowIndex == 0 && $0.panelIndex == 2 }
        precondition(sheetReport.targetMatched && !otherPanel.isEmpty)
        precondition(otherPanel.allSatisfy { $0.labels.isEmpty && $0.actions.isEmpty && $0.identifier == nil })
    }
    private static func notificationCenterNeverReadsContent() throws {
        var nodes = base()
        nodes[1]?.strings["AXIdentifier"] = "notificationContainerView"
        nodes[4]?.strings["AXIdentifier"] = "com.apple.FaceTime.FaceTimeNotificationExtension"
        nodes[5]?.strings["AXIdentifier"] = "unrelated-private-notification-token"
        nodes[5]?.strings["AXTitle"] = "+13125550123"
        nodes[5]?.strings["AXValue"] = "Private Notification Message"
        nodes[5]?.strings["AXHelp"] = "Private Notification Help"
        nodes[5]?.processIdentifier = 77 // Remote owner does not change the structure-only policy.
        for expected in [nil, try PhoneNumber("+13125550123")] {
            let provider = FixtureProvider(nodes)
            var scanner = PhoneProbeScanner(provider: provider, expected: expected, cancellation: PhoneProbeCancellation())
            let report = scanner.scan([notificationCenter])
            precondition(!report.targetMatched && report.phoneStatus == "unknown" && report.candidates[0].structureOnly)
            let permitted: Set<String> = ["application", "timeout", "AXWindows", "AXChildren", "AXRole", "AXSubrole", "AXIdentifier", "pid"]
            precondition(provider.reads.allSatisfy { permitted.contains($0.1) })
            precondition(provider.reads.contains { $0.0 == 5 && $0.1 == "AXIdentifier" }) // Lists traverse structure only.
            let elements = report.candidates[0].elements
            precondition(elements.allSatisfy { $0.labels.isEmpty && $0.actions.isEmpty && $0.enabled == nil && $0.panelIndex == 0 })
            precondition(elements.first?.childCount == 3 && elements.first?.childPath == [] && elements.first?.identifier == "notificationContainerView")
            let embedded = elements.first { $0.childPath == [2] }
            precondition(embedded?.identifier == "com.apple.FaceTime.FaceTimeNotificationExtension")
            let remote = elements.first { $0.childPath == [2, 0] }
            precondition(remote?.elementProcessIdentifier == 77 && remote?.identifier == "[redacted]" && remote?.childCount == 0)
            let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
            for secret in ["Private Contact", "Private History", "Private Notification", "13125550123", "unrelated-private-notification-token"] {
                precondition(!encoded.contains(secret))
            }
            let decoded = try JSONDecoder().decode(PhoneControlReport.self, from: JSONEncoder().encode(report))
            precondition(decoded == report)
        }
    }
    private static func notificationCenterScopeRemainsBounded() throws {
        var nodes: [Int: FixtureNode] = [0: FixtureNode(children: ["AXWindows": Array(1...20)])]
        for index in 1...200 {
            nodes[index] = FixtureNode(strings: ["AXRole": index <= 20 ? "AXWindow" : "AXList", "AXIdentifier": "notificationList"],
                                      children: ["AXChildren": Array((index * 10)...(index * 10 + 19))])
        }
        let provider = FixtureProvider(nodes)
        var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let report = scanner.scan([notificationCenter])
        precondition(report.truncated && report.operations <= 300 && report.visitedElements <= 128 && provider.calls == report.operations)
        precondition(provider.childLimits.allSatisfy { $0 <= 8 })
        precondition(report.candidates[0].windowCount == 20)
        precondition(report.candidates[0].elements.allSatisfy { $0.windowIndex < 8 && $0.childPath.count == $0.depth && $0.depth <= 8 && $0.childPath.allSatisfy { $0 < 8 } })
        var deep: [Int: FixtureNode] = [0: FixtureNode(children: ["AXWindows": [1]])]
        for index in 1...20 { deep[index] = FixtureNode(strings: ["AXRole": index == 1 ? "AXWindow" : "AXList"], children: ["AXChildren": [index + 1]]) }
        var deepScanner = PhoneProbeScanner(provider: FixtureProvider(deep), expected: nil, cancellation: PhoneProbeCancellation())
        let deepReport = deepScanner.scan([notificationCenter])
        let deepest = deepReport.candidates[0].elements.last
        precondition(deepReport.truncated && deepest?.depth == 8 && deepest?.childCount == 1)
    }
    private static func embeddedFixture() -> ([Int: FixtureNode], PhoneProbeCandidate, PhoneProbeCandidate) {
        let bridge = PhoneProbeCandidate(bundleIdentifier: "com.apple.facetime.NotificationViewBridgeService", processIdentifier: 88,
                                         bundlePath: "/System/Library/PrivateFrameworks/FaceTimeNotificationViewBridge.framework/Versions/A/XPCServices/FaceTimeNotificationViewBridgeService.xpc", launchTime: 100)
        let extensionOwner = PhoneProbeCandidate(bundleIdentifier: "com.apple.FaceTime.FaceTimeNotificationExtension", processIdentifier: 89,
                                                 bundlePath: "/System/Library/ExtensionKit/Extensions/FaceTimeNotificationExtension.appex", launchTime: 101)
        let nodes: [Int: FixtureNode] = [
            0: FixtureNode(children: ["AXWindows": [1]]),
            1: FixtureNode(strings: ["AXRole": "AXWindow", "AXTitle": "+13125550123"], children: ["AXChildren": [2]]),
            2: FixtureNode(strings: ["AXRole": "AXGroup"], children: ["AXChildren": [3, 4]], processIdentifier: 88, advertised: ["AXChildren"]),
            3: FixtureNode(strings: ["AXRole": "AXGroup", "AXTitle": "+13125550123", "AXDescription": "Private Caller"],
                           children: ["AXChildrenInNavigationOrder": [5, 6], "AXContents": [5], "AXVisibleChildren": [6]],
                           processIdentifier: 89, advertised: ["AXTitle", "AXDescription", "AXChildrenInNavigationOrder", "AXContents", "AXVisibleChildren", "AXPosition", "AXSize", "private-attribute-token"],
                           geometry: ["AXPosition": [100, 200], "AXSize": [400, 200]]),
            4: FixtureNode(strings: ["AXRole": "AXGroup", "AXTitle": "Unrelated Notification"], children: ["AXChildren": [7]]),
            5: FixtureNode(strings: ["AXRole": "AXButton", "AXTitle": "End Call", "AXIdentifier": "endCallButton"], actions: ["AXPress"], processIdentifier: 89, advertised: ["AXTitle"]),
            6: FixtureNode(strings: ["AXRole": "AXButton", "AXTitle": "+13125550123", "AXValue": "Unrelated private content"], actions: ["AXPress"], processIdentifier: 901, advertised: ["AXTitle", "AXValue"]),
            7: FixtureNode(strings: ["AXRole": "AXGroup", "AXTitle": "Call"], actions: ["AXPress"], processIdentifier: 88, advertised: ["AXTitle"])
        ]
        return (nodes, bridge, extensionOwner)
    }
    private static func embeddedOwnerDiscoveryIsScopedAndBounded() throws {
        let (nodes, bridge, extensionOwner) = embeddedFixture()
        let provider = FixtureProvider(nodes)
        provider.currentIdentities = [88: bridge, 89: extensionOwner]
        var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let report = scanner.scan([notificationCenter, bridge, extensionOwner])
        let nc = report.candidates[0]
        precondition(!nc.structureOnly && nc.embeddedPhoneInspection && report.targetMatched && report.phoneStatus == "unknown")
        let root = nc.elements.first { $0.elementReference == 3 }!
        precondition(root.phoneOwnerVerified && root.labels.contains("[target number]") && root.childCount == 0)
        precondition(root.supportedAttributes.contains("[redacted]") && root.supportedAttributeCount == 8)
        precondition(root.navigationChildCounts == ["AXChildrenInNavigationOrder": 2, "AXContents": 1, "AXVisibleChildren": 1])
        precondition(root.childEdges.count == 4 && root.bounds == PhoneControlBounds(x: 100, y: 200, width: 400, height: 200))
        let button = nc.elements.first { $0.elementReference == 5 }!
        precondition(button.labels == ["End Call"] && button.actions == ["AXPress"] && button.panelIndex == root.panelIndex)
        precondition(button.childAttributePath.last == "AXChildrenInNavigationOrder")
        let foreign = nc.elements.first { $0.elementReference == 6 }!
        precondition(!foreign.phoneOwnerVerified && foreign.labels.isEmpty && foreign.actions.isEmpty && foreign.supportedAttributes.isEmpty)
        let unmatchedPanel = nc.elements.first { $0.elementReference == 7 }!
        precondition(unmatchedPanel.phoneOwnerVerified && unmatchedPanel.panelIndex != root.panelIndex && unmatchedPanel.labels.isEmpty && unmatchedPanel.actions.isEmpty)
        for forbidden in [1, 4, 6] {
            precondition(!provider.reads.contains { $0.0 == forbidden && ["AXTitle", "AXValue", "AXDescription", "attributes", "actions", "AXPosition", "AXSize"].contains($0.1) })
        }
        precondition(!provider.reads.contains { $0.0 == 2 && ["AXContents", "AXVisibleChildren", "AXChildrenInNavigationOrder"].contains($0.1) })
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for secret in ["Private Caller", "Unrelated", "13125550123", "private-attribute-token"] { precondition(!encoded.contains(secret)) }
        precondition(provider.calls == report.operations && report.operations <= 300)
        // Without an exact target, numeric geometry and attribute names remain useful; labels/actions are absent.
        let metadataProvider = FixtureProvider(nodes); metadataProvider.currentIdentities = provider.currentIdentities
        var metadataScanner = PhoneProbeScanner(provider: metadataProvider, expected: nil, cancellation: PhoneProbeCancellation())
        let metadataReport = metadataScanner.scan([notificationCenter, bridge, extensionOwner])
        precondition(!metadataReport.targetMatched)
        precondition(metadataReport.candidates[0].elements.first { $0.elementReference == 3 }?.bounds != nil)
        precondition(!metadataProvider.reads.contains { ["AXTitle", "AXValue", "AXDescription", "actions"].contains($0.1) })
        var wide = nodes
        wide[3]?.children["AXChildrenInNavigationOrder"] = Array(20...50)
        wide[3]?.children["AXContents"] = Array(20...50)
        wide[3]?.advertised += Array(repeating: "private-long-attribute", count: 80)
        for index in 20...50 { wide[index] = FixtureNode(strings: ["AXRole": "AXGroup"], processIdentifier: 89) }
        let wideProvider = FixtureProvider(wide); wideProvider.currentIdentities = provider.currentIdentities
        var wideScanner = PhoneProbeScanner(provider: wideProvider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let wideReport = wideScanner.scan([notificationCenter, bridge, extensionOwner])
        precondition(wideReport.truncated && wideReport.operations <= 300 && wideReport.visitedElements <= 128 && wideProvider.childLimits.allSatisfy { $0 <= 8 })
        precondition(wideReport.candidates[0].elements.allSatisfy { $0.supportedAttributes.count <= 64 && $0.depth <= 8 })
    }
    private static func embeddedOwnerIdentityCannotBeReusedOrInherited() throws {
        let (nodes, bridge, extensionOwner) = embeddedFixture()
        var reusedBridge = bridge; reusedBridge.launchTime = 999
        var reusedExtension = extensionOwner; reusedExtension.bundlePath = "/Applications/Untrusted.app"
        for mode in 0...3 {
            let provider = FixtureProvider(nodes)
            var owners = [bridge, extensionOwner]
            switch mode {
            case 0: provider.currentIdentities = [88: reusedBridge, 89: reusedExtension]
            case 1: owners = []; provider.currentIdentities = [88: bridge, 89: extensionOwner]
            case 2: owners[0].bundlePath = "/Applications/Fake.app"; owners[1].launchTime = nil
                provider.currentIdentities = [88: bridge, 89: extensionOwner]
            default: owners += [PhoneProbeCandidate(bundleIdentifier: "com.apple.mobilephone", processIdentifier: 88),
                                PhoneProbeCandidate(bundleIdentifier: "com.apple.facetime.NotificationService", processIdentifier: 89)]
                provider.currentIdentities = [88: bridge, 89: extensionOwner]
            }
            var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
            let report = scanner.scan([notificationCenter] + owners)
            precondition(!report.targetMatched && !report.candidates[0].embeddedPhoneInspection)
            precondition(!provider.reads.contains { ["attributes", "AXTitle", "AXValue", "AXDescription", "actions", "AXPosition", "AXSize", "AXContents", "AXVisibleChildren", "AXChildrenInNavigationOrder"].contains($0.1) })
        }
        // Reuse between privileged reads is checked again, rather than trusting a prior verification.
        let provider = FixtureProvider(nodes); provider.currentIdentities = [88: bridge, 89: extensionOwner]
        provider.afterCall = {
            if provider.reads.last?.0 == 3 && provider.reads.last?.1 == "attributes" { provider.currentIdentities[89] = reusedExtension }
        }
        var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let report = scanner.scan([notificationCenter, bridge, extensionOwner])
        precondition(!report.targetMatched)
        precondition(!provider.reads.contains { $0.0 == 3 && ["AXTitle", "AXDescription", "actions", "AXPosition", "AXSize", "AXContents", "AXVisibleChildren", "AXChildrenInNavigationOrder"].contains($0.1) })
    }
    private static func processStartIdentityAllowsHelpersWithoutLaunchDate() throws {
        let (nodes, originalBridge, originalExtension) = embeddedFixture()
        var bridge = originalBridge, extensionOwner = originalExtension
        bridge.launchTime = nil; extensionOwner.launchTime = nil
        bridge.processStart = PhoneProbeProcessStart(seconds: 1_000, microseconds: 123)
        extensionOwner.processStart = PhoneProbeProcessStart(seconds: 1_000, microseconds: 456)
        let provider = FixtureProvider(nodes); provider.currentIdentities = [88: bridge, 89: extensionOwner]
        var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let report = scanner.scan([notificationCenter, bridge, extensionOwner])
        precondition(report.targetMatched && report.candidates[0].embeddedPhoneInspection)
        precondition(report.candidates[0].elements.first { $0.elementReference == 3 }?.phoneOwnerVerified == true)
        // Same bundle/path/PID with a different process start is a reused PID and must fail closed.
        var replacementBridge = bridge, replacementExtension = extensionOwner
        replacementBridge.processStart = PhoneProbeProcessStart(seconds: 1_001, microseconds: 123)
        replacementExtension.processStart = PhoneProbeProcessStart(seconds: 1_000, microseconds: 457)
        let reused = FixtureProvider(nodes); reused.currentIdentities = [88: replacementBridge, 89: replacementExtension]
        var reusedScanner = PhoneProbeScanner(provider: reused, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let reusedReport = reusedScanner.scan([notificationCenter, bridge, extensionOwner])
        precondition(!reusedReport.targetMatched && !reusedReport.candidates[0].embeddedPhoneInspection)
        precondition(!reused.reads.contains { ["attributes", "AXTitle", "AXValue", "AXDescription", "actions", "AXPosition", "AXSize"].contains($0.1) })
        let changing = FixtureProvider(nodes); changing.currentIdentities = [88: bridge, 89: extensionOwner]
        changing.afterCall = {
            if changing.reads.last?.0 == 3 && changing.reads.last?.1 == "attributes" { changing.currentIdentities[89] = replacementExtension }
        }
        var changingScanner = PhoneProbeScanner(provider: changing, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        precondition(!changingScanner.scan([notificationCenter, bridge, extensionOwner]).targetMatched)
        precondition(!changing.reads.contains { $0.0 == 3 && ["AXTitle", "AXDescription", "actions", "AXPosition", "AXSize"].contains($0.1) })
    }
    private static func limitsAndCycleHandling() throws {
        var nodes = base()
        nodes[0]?.children["AXWindows"] = Array(repeating: 1, count: 20)
        nodes[1]?.children["AXChildren"] = [2, 3, 4, 1] + Array(10...30)
        for index in 10...30 { nodes[index] = FixtureNode(strings: ["AXRole": "AXGroup"], children: ["AXChildren": [index + 1]]) }
        let provider = FixtureProvider(nodes)
        var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let report = scanner.scan(Array(repeating: helper, count: 20))
        precondition(report.truncated && report.candidates.count <= 8 && report.operations <= 300 && report.visitedElements <= 128)
        precondition(provider.childLimits.allSatisfy { $0 <= 8 })
        precondition(report.candidates.flatMap(\.elements).allSatisfy { $0.depth <= 8 })
        // Every provider operation is charged, including per-element timeout setup.
        precondition(provider.calls == report.operations)
        var deep: [Int: FixtureNode] = [0: FixtureNode(children: ["AXWindows": [1]])]
        for index in 1...20 { deep[index] = FixtureNode(strings: ["AXRole": index == 1 ? "AXWindow" : "AXGroup"], children: ["AXChildren": [index + 1]]) }
        var depthScanner = PhoneProbeScanner(provider: FixtureProvider(deep), expected: try PhoneNumber("+13125550123"), cancellation: PhoneProbeCancellation())
        let depthReport = depthScanner.scan([helper]); precondition(depthReport.truncated)
        precondition(depthReport.candidates[0].elements.map(\.depth).max() == 8)
    }
    private static func deadlineOperationNodeAndCancellationBudgets() {
        let token = PhoneProbeCancellation()
        var time = 0.0
        var budget = PhoneProbeBudget(cancellation: token, now: { time })
        for _ in 0..<300 { precondition(budget.operation()) }
        precondition(!budget.operation() && budget.truncated)
        budget = PhoneProbeBudget(cancellation: token, now: { time })
        for _ in 0..<128 { precondition(budget.visit(depth: 1)) }
        precondition(!budget.visit(depth: 1) && budget.truncated)
        budget = PhoneProbeBudget(cancellation: token, now: { time })
        time = 2; precondition(!budget.operation() && budget.truncated)
        time = 0; budget = PhoneProbeBudget(cancellation: token, now: { time })
        precondition(!budget.visit(depth: 9))
        token.cancel(); precondition(!budget.operation())
    }
    private static func cancellationStopsSubsequentReads() throws {
        let token = PhoneProbeCancellation(), provider = FixtureProvider(base())
        provider.afterCall = { if provider.calls == 7 { token.cancel() } }
        var scanner = PhoneProbeScanner(provider: provider, expected: try PhoneNumber("+13125550123"), cancellation: token)
        let report = scanner.scan([helper])
        precondition(report.cancelled && provider.calls == 7 && report.operations == 7 && report.phoneStatus == "unknown")
    }
    @MainActor private static func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Fixture worker did not complete")
    }
    @MainActor private static func probeLifecycle() async {
        var permissionChecks = 0, captures = 0
        let gate = Gate()
        let probe = PhoneControlProbe(candidates: { captures += 1; return [helper] }, permission: { permissionChecks += 1; return true }) { candidates, expected, token in
            let call = gate.enter()
            if call == 1 { gate.release.wait() }
            var scanner = PhoneProbeScanner(provider: FixtureProvider(base()), expected: expected, cancellation: token)
            return scanner.scan(candidates)
        }
        probe.start(expectedNumber: "3125550123")
        probe.start(expectedNumber: "+1 312 555 0123")
        precondition(probe.state == .finished && permissionChecks == 0 && captures == 0 && gate.calls == 0)
        probe.start(expectedNumber: "+13125550123")
        probe.start(expectedNumber: "+442079460123")
        precondition(probe.state == .running && permissionChecks == 1 && captures == 1)
        await waitUntil { gate.calls == 1 }
        probe.cancel(); precondition(probe.state == .cancelled && probe.report == nil)
        for _ in 0..<20 { probe.start() }
        precondition(captures == 1 && gate.calls == 1) // Cannot enqueue work behind cancelled-but-running scan.
        gate.release.signal()
        await waitUntil { !probe.workerBusy }
        precondition(probe.state == .cancelled && probe.report == nil) // Stale result discarded.
        probe.start(expectedNumber: "+13125550123")
        await waitUntil { probe.state == .finished }
        precondition(gate.calls == 2 && probe.report?.targetMatched == true && probe.reportJSON()?.contains("Private Contact") == false)
        let denied = PhoneControlProbe(candidates: { preconditionFailure("No capture on denied permission") }, permission: { false }) { _, _, _ in
            preconditionFailure("No scan on denied permission")
        }
        denied.start()
        precondition(denied.state == .finished && denied.report?.permissionGranted == false && denied.status.contains("System Settings"))
    }
}
