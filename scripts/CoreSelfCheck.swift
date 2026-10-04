import Foundation

@main
struct CoreSelfCheck {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Core check failed: " + message) }
            checks += 1
        }
        let number = try PhoneNumber(" +1 (202) 555-0146 ")
        check(number.normalized == "+12025550146", "normalizes supported formatting")
        check(number.masked == "+•••••••0146", "masks all but four digits")
        check(number.description == number.masked, "default logging is masked")
        let minimum = try PhoneNumber("+12345678"), maximum = try PhoneNumber("+123456789012345")
        check(minimum.normalized == "+12345678", "minimum digit boundary")
        check(maximum.normalized == "+123456789012345", "maximum digit boundary")
        for raw in ["2025550146", "+0123456789", "+1234567", "+1234567890123456",
                    "tel:+12025550146", "+12025550146;ext=2", "+12025550146#", "++12025550146",
                    "+１２０２５５５０１４６", "+12025550146\n", "+1\u{200B}2025550146"] {
            do { _ = try PhoneNumber(raw); fatalError("Core check failed: invalid number accepted") }
            catch { checks += 1 }
        }
        var call = CallLifecycle()
        let first = UUID(), other = UUID()
        check(call.reduce(.begin(first)), "first attempt accepted")
        check(!call.reduce(.begin(other)), "duplicate attempt rejected")
        check(call.reduce(.requestSubmitted(first)), "handoff submission recorded")
        check(call.state == .requestSubmitted(first), "submission never implies connected")
        check(call.reduce(.externalCallStatusUnavailable(first)), "external status explicitly unknown")
        check(!call.canStartNewCall, "unknown status locks another attempt")
        check(!call.reduce(.userConfirmedEnded(other)), "stale user report rejected")
        check(!call.reduce(.ended(first, .userConfirmedEnded)), "user report cannot masquerade as backend end")
        check(call.reduce(.userConfirmedEnded(first)), "explicit user reconciliation accepted")
        check(call.state == .ended(first, .userConfirmedEnded), "report retains distinct evidence type")
        check(call.canStartNewCall, "reconciliation unlocks")
        check(!call.reduce(.connected(first)), "ended call cannot resurrect")
        check(!call.reduce(.begin(first)), "same attempt ID cannot restart")
        check(call.reduce(.begin(other)), "new attempt starts")
        check(call.reduce(.requestOutcomeUnknown(other)), "ambiguous request recorded")
        check(!call.canStartNewCall, "ambiguous request prevents retry")
        check(!call.reduce(.ended(first, .completed)), "stale completion ignored")
        check(!call.reduce(.hangupUIPanelClosed(other)), "panel closure requires requested end")
        check(!call.reduce(.ended(other, .hangupUIPanelClosed)), "UI receipt cannot masquerade as carrier evidence")
        check(call.reduce(.requestEnd(other)), "ambiguous handoff accepts single end request")
        check(!call.reduce(.hangupUIPanelClosed(first)), "stale panel receipt rejected")
        check(call.reduce(.hangupUIPanelClosed(other)), "target-bound hangup receipt accepted")
        check(call.state == .ended(other, .hangupUIPanelClosed), "UI evidence remains distinct")
        check(call.state.title == "Hangup sent · popup closed", "title does not claim carrier end")
        check(call.canStartNewCall && !call.reduce(.connected(other)), "UI receipt releases local job without resurrecting it")
        check(!CallRoute.phoneRelay.capabilities.supportsProgrammaticAudio, "Phone route does not claim audio")
        print("CallCore portable checks passed: \(checks)")
    }
}
