import Foundation
import AppKit
@preconcurrency import ApplicationServices
import CallCore

/// Implementations are constructed, used and destroyed on the worker queue.
/// Tokens are local integer handles; AX objects never leave the live implementation.
protocol PhoneProbeProvider: AnyObject {
    func application(pid: Int32) -> Int
    func timeout(_ element: Int) -> Int32
    func string(_ element: Int, attribute: String) -> (String?, Int32)
    func bool(_ element: Int, attribute: String) -> (Bool?, Int32)
    func count(_ element: Int, attribute: String) -> (Int?, Int32)
    func children(_ element: Int, attribute: String, limit: Int) -> ([Int], Int32)
    func actions(_ element: Int) -> ([String], Int32)
    func processIdentifier(_ element: Int) -> (Int32?, Int32)
    func attributes(_ element: Int) -> ([String], Int, Int32)
    func isCurrentCandidate(_ candidate: PhoneProbeCandidate) -> Bool
    func geometry(_ element: Int, attribute: String) -> ((Double, Double)?, Int32)
}

private final class LivePhoneProbeProvider: PhoneProbeProvider {
    private var elements: [Int: AXUIElement] = [:]
    private var next = 0
    private func retain(_ element: AXUIElement) -> Int {
        if let existing = elements.first(where: { CFEqual($0.value, element) }) { return existing.key }
        next += 1; elements[next] = element; return next
    }
    func application(pid: Int32) -> Int { retain(AXUIElementCreateApplication(pid)) }
    func timeout(_ element: Int) -> Int32 {
        AXUIElementSetMessagingTimeout(elements[element]!, 0.15).rawValue
    }
    func string(_ element: Int, attribute: String) -> (String?, Int32) {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(elements[element]!, attribute as CFString, &result)
        return (result as? String, error.rawValue)
    }
    func bool(_ element: Int, attribute: String) -> (Bool?, Int32) {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(elements[element]!, attribute as CFString, &result)
        // Do not coerce arbitrary free-text values.
        guard let result, CFGetTypeID(result) == CFBooleanGetTypeID() else { return (nil, error.rawValue) }
        return (CFBooleanGetValue((result as! CFBoolean)), error.rawValue)
    }
    func count(_ element: Int, attribute: String) -> (Int?, Int32) {
        var count: CFIndex = 0
        let error = AXUIElementGetAttributeValueCount(elements[element]!, attribute as CFString, &count)
        return (error == .success ? count : nil, error.rawValue)
    }
    func children(_ element: Int, attribute: String, limit: Int) -> ([Int], Int32) {
        var result: CFArray?
        let error = AXUIElementCopyAttributeValues(elements[element]!, attribute as CFString, 0, limit, &result)
        guard let result else { return ([], error.rawValue) }
        var handles: [Int] = []
        for value in (result as [AnyObject]).prefix(limit) where CFGetTypeID(value) == AXUIElementGetTypeID() {
            handles.append(retain(value as! AXUIElement))
        }
        return (handles, error.rawValue)
    }
    func actions(_ element: Int) -> ([String], Int32) {
        var result: CFArray?
        let error = AXUIElementCopyActionNames(elements[element]!, &result)
        return ((result as? [String] ?? []).prefix(8).map { $0 }, error.rawValue)
    }
    func processIdentifier(_ element: Int) -> (Int32?, Int32) {
        var pid: pid_t = 0
        let code = AXUIElementGetPid(elements[element]!, &pid)
        return (code == .success ? pid : nil, code.rawValue)
    }
    func attributes(_ element: Int) -> ([String], Int, Int32) {
        var result: CFArray?
        let code = AXUIElementCopyAttributeNames(elements[element]!, &result)
        let values = result as? [String] ?? []
        return (Array(values.prefix(64)), values.count, code.rawValue)
    }
    func isCurrentCandidate(_ candidate: PhoneProbeCandidate) -> Bool {
        // NSRunningApplication is documented thread-safe. Recheck immutable instance identity for
        // each privileged read; a captured PID by itself never grants content access after reuse.
        guard candidate.isEmbeddedPhoneOwner, let path = candidate.bundlePath,
              candidate.processStart != nil || candidate.launchTime != nil,
              let current = NSRunningApplication(processIdentifier: candidate.processIdentifier), !current.isTerminated,
              current.bundleIdentifier == candidate.bundleIdentifier,
              current.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path,
              PhoneProbePrivacy.trustedPath(bundle: candidate.bundleIdentifier, path: path) else { return false }
        if let start = candidate.processStart {
            guard PhoneProbeProcessMetadata.startTime(pid: candidate.processIdentifier) == start else { return false }
        }
        if let launchTime = candidate.launchTime {
            guard current.launchDate?.timeIntervalSince1970 == launchTime else { return false }
        }
        return true
    }
    func geometry(_ element: Int, attribute: String) -> ((Double, Double)?, Int32) {
        var result: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(elements[element]!, attribute as CFString, &result)
        guard let result, CFGetTypeID(result) == AXValueGetTypeID() else { return (nil, code.rawValue) }
        let value = result as! AXValue
        if attribute == "AXPosition", AXValueGetType(value) == .cgPoint {
            var point = CGPoint.zero
            if AXValueGetValue(value, .cgPoint, &point) { return ((point.x, point.y), code.rawValue) }
        }
        if attribute == "AXSize", AXValueGetType(value) == .cgSize {
            var size = CGSize.zero
            if AXValueGetValue(value, .cgSize, &size) { return ((size.width, size.height), code.rawValue) }
        }
        return (nil, code.rawValue)
    }
}

struct PhoneProbeScanner {
    let provider: any PhoneProbeProvider
    var budget: PhoneProbeBudget
    var report: PhoneControlReport
    let expected: PhoneNumber?
    private var prepared: Set<Int> = []
    private var visited: Set<Int> = []
    private var embeddedOwners: [Int32: PhoneProbeCandidate] = [:]
    private var nextEmbeddedPanel = 0

    init(provider: any PhoneProbeProvider, expected: PhoneNumber?, cancellation: PhoneProbeCancellation,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.provider = provider; self.expected = expected
        self.budget = PhoneProbeBudget(cancellation: cancellation, now: now)
        self.report = PhoneControlReport(metadataOnly: expected == nil, permissionGranted: true)
    }
    static func live(candidates: [PhoneProbeCandidate], expected: PhoneNumber?, cancellation: PhoneProbeCancellation) -> PhoneControlReport {
        var scanner = PhoneProbeScanner(provider: LivePhoneProbeProvider(), expected: expected, cancellation: cancellation)
        return scanner.scan(candidates)
    }
    private mutating func error(_ code: Int32) {
        // Unsupported/missing attributes are ordinary discovery results.
        guard code != 0, code != AXError.attributeUnsupported.rawValue, code != AXError.noValue.rawValue,
              report.errors.count < 16 else { return }
        let message = "Accessibility read returned code \(code)."
        if !report.errors.contains(message) { report.errors.append(message) }
    }
    private mutating func prepare(_ element: Int) -> Bool {
        if prepared.contains(element) { return true }
        guard budget.operation() else { return false }
        let code = provider.timeout(element); error(code)
        guard code == 0 else { return false }
        prepared.insert(element); return true
    }
    private mutating func string(_ element: Int, _ attribute: String) -> String? {
        guard prepare(element), budget.operation() else { return nil }
        let (value, code) = provider.string(element, attribute: attribute); error(code); return value
    }
    private mutating func children(_ element: Int, _ attribute: String) -> (Int?, [Int]) {
        guard prepare(element), budget.operation() else { return (nil, []) }
        let (count, countCode) = provider.count(element, attribute: attribute); error(countCode)
        guard let count, count > 0 else { return (count, []) }
        if count > 8 { budget.truncated = true }
        guard budget.operation() else { return (count, []) }
        let (children, code) = provider.children(element, attribute: attribute, limit: min(count, 8)); error(code)
        return (count, Array(children.prefix(8)))
    }
    private mutating func metadata(_ element: Int, depth: Int, textAllowed: Bool, windowIndex: Int, panelIndex: Int) -> PhoneControlElement? {
        guard !visited.contains(element), budget.visit(depth: depth), prepare(element) else { return nil }
        visited.insert(element)
        let role = PhoneProbePrivacy.structure(string(element, "AXRole")) ?? "unknown"
        let subrole = PhoneProbePrivacy.structure(string(element, "AXSubrole"))
        var identifier: String?, enabled: Bool?, actions: [String] = [], labels: [String] = []
        if textAllowed && !["AXTable", "AXOutline", "AXList"].contains(role) {
            identifier = PhoneProbePrivacy.identifier(string(element, "AXIdentifier"))
            if budget.operation() {
                let (value, code) = provider.bool(element, attribute: "AXEnabled"); error(code); enabled = value
            }
            if budget.operation() {
                let (values, code) = provider.actions(element); error(code)
                actions = values.prefix(8).map { PhoneProbePrivacy.actions.contains($0) ? $0 : "[redacted]" }
            }
            if ["AXButton", "AXStaticText", "AXTextField"].contains(role) {
                for attribute in ["AXTitle", "AXValue", "AXDescription"] {
                    if let value = string(element, attribute) {
                        let label = PhoneProbePrivacy.label(value, expected: expected)
                        if !labels.contains(label) { labels.append(label) }
                    }
                }
            }
        }
        return PhoneControlElement(role: role, subrole: subrole, identifier: identifier,
                                   actions: actions, enabled: enabled, labels: labels, depth: depth,
                                   windowIndex: windowIndex, panelIndex: panelIndex)
    }
    private mutating func subtree(_ root: Int, depth: Int, windowIndex: Int, panelIndex: Int,
                                 into candidate: inout PhoneControlCandidateReport) {
        guard let metadata = metadata(root, depth: depth, textAllowed: true, windowIndex: windowIndex, panelIndex: panelIndex) else { return }
        candidate.elements.append(metadata)
        guard !["AXTable", "AXOutline", "AXList"].contains(metadata.role) else { return }
        guard depth < 8 else { budget.truncated = true; return }
        let (_, descendants) = children(root, "AXChildren")
        for child in descendants { subtree(child, depth: depth + 1, windowIndex: windowIndex, panelIndex: panelIndex, into: &candidate) }
    }
    private mutating func panel(_ roots: [Int], windowIndex: Int, panelIndex: Int,
                               into candidate: inout PhoneControlCandidateReport) {
        var staged = PhoneControlCandidateReport(bundleIdentifier: candidate.bundleIdentifier, processIdentifier: candidate.processIdentifier)
        for root in roots { subtree(root, depth: 1, windowIndex: windowIndex, panelIndex: panelIndex, into: &staged) }
        let matched = staged.elements.contains { $0.labels.contains("[target number]") }
        if matched { report.targetMatched = true }
        candidate.elements.append(contentsOf: staged.elements.map {
            guard !matched else { return $0 }
            return PhoneControlElement(role: $0.role, subrole: $0.subrole, identifier: nil, actions: [], enabled: nil,
                                       labels: [], depth: $0.depth, windowIndex: $0.windowIndex, panelIndex: $0.panelIndex)
        })
    }
    private mutating func verifyOwner(_ element: Int, candidate: PhoneProbeCandidate) -> Bool {
        guard prepare(element), budget.operation() else { return false }
        let (pid, code) = provider.processIdentifier(element); error(code)
        guard pid == candidate.processIdentifier, budget.operation() else { return false }
        return provider.isCurrentCandidate(candidate)
    }
    private mutating func embeddedChildren(_ element: Int, attribute: String, owner: PhoneProbeCandidate,
                                          copyChildren: Bool) -> (Int?, [Int]) {
        guard verifyOwner(element, candidate: owner), budget.operation() else { return (nil, []) }
        let (count, code) = provider.count(element, attribute: attribute); error(code)
        guard let count, count > 0 else { return (count, []) }
        if !copyChildren || count > 8 { budget.truncated = true }
        guard copyChildren, verifyOwner(element, candidate: owner), budget.operation() else { return (count, []) }
        let (values, childCode) = provider.children(element, attribute: attribute, limit: min(count, 8)); error(childCode)
        return (count, Array(values.prefix(8)))
    }
    /// The mixed Notification Center host stays structure-only. Privileged discovery is restricted
    /// to independently verified bridge/extension elements, never inherited by their descendants.
    private mutating func structureSubtree(_ root: Int, depth: Int, windowIndex: Int, path: [Int],
                                          attributePath: [String], parentPanel: Int,
                                          into candidate: inout PhoneControlCandidateReport) {
        guard let base = metadata(root, depth: depth, textAllowed: false, windowIndex: windowIndex, panelIndex: 0) else { return }
        let identifier = PhoneProbePrivacy.identifier(string(root, "AXIdentifier"))
        var ownerPID: Int32?
        if budget.operation() {
            let (pid, code) = provider.processIdentifier(root); error(code); ownerPID = pid
        }
        let owner = ownerPID.flatMap { embeddedOwners[$0] }
        let verified = owner.map { verifyOwner(root, candidate: $0) } ?? false
        var panelIndex = 0
        if verified {
            if parentPanel > 0 { panelIndex = parentPanel }
            else { nextEmbeddedPanel += 1; panelIndex = nextEmbeddedPanel }
            candidate.embeddedPhoneInspection = true
            candidate.structureOnly = false
        }
        var element = PhoneControlElement(role: base.role, subrole: base.subrole, identifier: identifier,
                                          actions: [], enabled: nil, labels: [], depth: depth,
                                          windowIndex: windowIndex, panelIndex: panelIndex)
        element.childPath = path; element.childAttributePath = attributePath
        element.elementProcessIdentifier = ownerPID; element.elementReference = root
        element.phoneOwnerVerified = verified
        var advertised: [String] = []
        if verified, let owner, verifyOwner(root, candidate: owner), budget.operation() {
            let (names, total, code) = provider.attributes(root); error(code)
            advertised = Array(names.prefix(64)); element.supportedAttributeCount = total
            if total > 64 { budget.truncated = true }
            element.supportedAttributes = advertised.map { PhoneProbePrivacy.attributeNames.contains($0) ? $0 : "[redacted]" }
        }
        if verified, let owner {
            if expected != nil {
                if verifyOwner(root, candidate: owner), budget.operation() {
                    let (actions, code) = provider.actions(root); error(code)
                    element.actions = actions.prefix(8).map { PhoneProbePrivacy.actions.contains($0) ? $0 : "[redacted]" }
                }
                if ["AXGroup", "AXButton", "AXStaticText", "AXTextField"].contains(base.role) {
                    for attribute in ["AXTitle", "AXValue", "AXDescription"] where advertised.contains(attribute) {
                        guard verifyOwner(root, candidate: owner) else { continue }
                        if let value = string(root, attribute) {
                            let label = PhoneProbePrivacy.label(value, expected: expected)
                            if !element.labels.contains(label) { element.labels.append(label) }
                        }
                    }
                }
            }
            var position: (Double, Double)?, size: (Double, Double)?
            for attribute in ["AXPosition", "AXSize"] where advertised.contains(attribute) {
                guard verifyOwner(root, candidate: owner), budget.operation() else { continue }
                let (value, code) = provider.geometry(root, attribute: attribute); error(code)
                if attribute == "AXPosition" { position = value } else { size = value }
            }
            if let position, let size, [position.0, position.1, size.0, size.1].allSatisfy({ $0.isFinite && abs($0) < 10_000_000 }),
               size.0 >= 0, size.1 >= 0 {
                element.bounds = PhoneControlBounds(x: position.0, y: position.1, width: size.0, height: size.1)
            }
        }
        var paths: [(String, [Int])] = []
        if depth < 8 {
            let (count, values) = children(root, "AXChildren"); element.childCount = count
            paths.append(("AXChildren", values))
        } else if budget.operation() {
            let (count, code) = provider.count(root, attribute: "AXChildren"); error(code); element.childCount = count
            if (count ?? 0) > 0 { budget.truncated = true }
        }
        // Public AppKit constant, rather than a guessed attribute spelling.
        let navigation = NSAccessibility.Attribute.childrenInNavigationOrderAttribute.rawValue
        if verified, let owner {
            for attribute in [navigation, "AXContents", "AXVisibleChildren"] where advertised.contains(attribute) {
                let (count, values) = embeddedChildren(root, attribute: attribute, owner: owner, copyChildren: depth < 8)
                if let count { element.navigationChildCounts[attribute] = count }
                paths.append((attribute, values))
            }
        }
        for (attribute, children) in paths {
            for (index, child) in children.enumerated() {
                element.childEdges.append(PhoneControlChildEdge(attribute: attribute, index: index, elementReference: child))
            }
        }
        candidate.elements.append(element)
        for (attribute, children) in paths {
            for (index, child) in children.enumerated() {
                structureSubtree(child, depth: depth + 1, windowIndex: windowIndex, path: path + [index],
                                 attributePath: attributePath + [attribute], parentPanel: panelIndex, into: &candidate)
            }
        }
    }
    mutating func scan(_ candidates: [PhoneProbeCandidate]) -> PhoneControlReport {
        // Duplicate PID ownership is ambiguous and never grants content access.
        for candidate in candidates where candidate.isEmbeddedPhoneOwner {
            guard candidates.filter({ $0.processIdentifier == candidate.processIdentifier }).count == 1,
                  let path = candidate.bundlePath, candidate.launchTime != nil || candidate.processStart != nil,
                  PhoneProbePrivacy.trustedPath(bundle: candidate.bundleIdentifier, path: path) else { continue }
            embeddedOwners[candidate.processIdentifier] = candidate
        }
        if candidates.count > 8 { budget.truncated = true }
        for candidate in candidates.prefix(8) {
            guard budget.operation() else { break }
            let application = provider.application(pid: candidate.processIdentifier)
            var result = PhoneControlCandidateReport(bundleIdentifier: candidate.bundleIdentifier, processIdentifier: candidate.processIdentifier)
            result.structureOnly = candidate.isStructureOnly
            let (count, windows) = children(application, "AXWindows"); result.windowCount = count ?? 0
            for (windowIndex, window) in windows.enumerated() {
                if candidate.isStructureOnly {
                    let start = result.elements.count
                    structureSubtree(window, depth: 0, windowIndex: windowIndex, path: [], attributePath: [], parentPanel: 0, into: &result)
                    let matchedPanels = Set(result.elements[start...].filter { $0.labels.contains("[target number]") }.map(\.panelIndex))
                    if !matchedPanels.isEmpty { report.targetMatched = true }
                    for index in start..<result.elements.count where !matchedPanels.contains(result.elements[index].panelIndex) {
                        result.elements[index].labels = []; result.elements[index].actions = []
                    }
                    continue
                }
                guard let windowInfo = metadata(window, depth: 0, textAllowed: false, windowIndex: windowIndex, panelIndex: 0) else { continue }
                result.elements.append(windowInfo)
                guard expected != nil else { continue }
                if candidate.isMainPhone {
                    let explicitDialog = ["AXSheet", "AXDialog"].contains(windowInfo.role)
                        || ["AXDialog", "AXSystemDialog"].contains(windowInfo.subrole ?? "")
                    if explicitDialog {
                        let (_, descendants) = children(window, "AXChildren")
                        panel(descendants, windowIndex: windowIndex, panelIndex: 1, into: &result)
                    } else {
                        // Never descend ordinary Phone windows, contacts, tables, lists or history.
                        let (_, sheets) = children(window, "AXSheets")
                        for (sheetIndex, sheet) in sheets.enumerated() {
                            guard string(sheet, "AXRole") == "AXSheet" else { continue }
                            panel([sheet], windowIndex: windowIndex, panelIndex: sheetIndex + 1, into: &result)
                        }
                    }
                } else {
                    let (_, descendants) = children(window, "AXChildren")
                    panel(descendants, windowIndex: windowIndex, panelIndex: 1, into: &result)
                }
            }
            report.candidates.append(result)
        }
        report.operations = budget.operations; report.visitedElements = budget.nodes
        report.truncated = budget.truncated; report.cancelled = budget.cancellation.isCancelled
        report.elapsedSeconds = max(0, budget.now() - budget.start)
        return report
    }
}
