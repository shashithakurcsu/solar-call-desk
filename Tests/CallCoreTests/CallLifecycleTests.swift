import Foundation
import XCTest
@testable import CallCore

final class CallLifecycleTests: XCTestCase {
    func testHandoffSuccessNeverImpliesRingingOrConnected() {
        var call = CallLifecycle()
        let id = UUID()
        XCTAssertTrue(call.reduce(.begin(id)))
        XCTAssertTrue(call.reduce(.requestSubmitted(id)))
        XCTAssertEqual(call.state, .requestSubmitted(id))
        XCTAssertFalse(call.canStartNewCall)
        XCTAssertTrue(call.reduce(.externalCallStatusUnavailable(id)))
        XCTAssertEqual(call.state, .unverified(id, .externalCallStatusUnavailable))
        XCTAssertTrue(call.needsReconciliation)
        XCTAssertFalse(call.reduce(.begin(UUID())))
        XCTAssertFalse(call.canStartNewCall)
    }

    func testAmbiguousRequestBlocksAnotherCallUntilVerifiedEnded() {
        var call = CallLifecycle()
        let id = UUID()
        call.reduce(.begin(id))
        XCTAssertTrue(call.reduce(.requestOutcomeUnknown(id)))
        XCTAssertFalse(call.reduce(.begin(UUID())))
        XCTAssertFalse(call.reduce(.begin(id)))
        XCTAssertEqual(call.activeAttemptID, id)
        XCTAssertTrue(call.reduce(.ended(id, .remoteEnded)))
        XCTAssertNil(call.activeAttemptID)
        XCTAssertTrue(call.canStartNewCall)
        XCTAssertTrue(call.reduce(.begin(UUID())))
    }

    func testUserConfirmationRemainsDistinctFromBackendEvidence() {
        var call = CallLifecycle()
        let id = UUID()
        call.reduce(.begin(id))
        call.reduce(.requestSubmitted(id))
        call.reduce(.externalCallStatusUnavailable(id))
        XCTAssertFalse(call.reduce(.ended(id, .userConfirmedEnded)))
        XCTAssertFalse(call.reduce(.userConfirmedEnded(UUID())))
        XCTAssertTrue(call.reduce(.userConfirmedEnded(id)))
        XCTAssertEqual(call.state, .ended(id, .userConfirmedEnded))
        XCTAssertTrue(call.canStartNewCall)
    }

    func testEndRequestAndUnknownEndDoNotClaimEndedOrAllowRetry() {
        var call = CallLifecycle()
        let id = UUID()
        call.reduce(.begin(id))
        call.reduce(.connected(id))
        XCTAssertTrue(call.reduce(.requestEnd(id)))
        XCTAssertEqual(call.state, .ending(id))
        XCTAssertFalse(call.canStartNewCall)
        XCTAssertFalse(call.reduce(.requestEnd(id)))
        XCTAssertFalse(call.reduce(.connected(id)))
        XCTAssertTrue(call.reduce(.endOutcomeUnknown(id)))
        XCTAssertEqual(call.state, .unverified(id, .endOutcomeUnknown))
        XCTAssertFalse(call.reduce(.requestEnd(id)))
        XCTAssertFalse(call.reduce(.begin(UUID())))
        XCTAssertFalse(call.reduce(.ringing(id)))
        XCTAssertFalse(call.reduce(.connected(id)))
        XCTAssertTrue(call.reduce(.ended(id, .completed)))
        XCTAssertEqual(call.state, .ended(id, .completed))
    }

    func testStaleAndOutOfOrderEventsCannotResurrectOrRegressCall() {
        var call = CallLifecycle()
        let first = UUID()
        let second = UUID()
        call.reduce(.begin(first))
        call.reduce(.connected(first))
        XCTAssertFalse(call.reduce(.requestSubmitted(first)))
        XCTAssertFalse(call.reduce(.ringing(first)))
        XCTAssertFalse(call.reduce(.requestOutcomeUnknown(first)))
        XCTAssertFalse(call.reduce(.rejectedBeforeDial(first)))
        XCTAssertEqual(call.state, .connected(first))
        call.reduce(.ended(first, .remoteEnded))
        XCTAssertFalse(call.reduce(.connected(first)))
        XCTAssertFalse(call.reduce(.begin(first)))
        XCTAssertTrue(call.reduce(.begin(second)))
        XCTAssertFalse(call.reduce(.ended(first, .remoteEnded)))
        XCTAssertFalse(call.reduce(.connected(first)))
        XCTAssertEqual(call.state, .requesting(second))
    }

    func testDefinitiveRejectionAllowsNewAttemptButAmbiguousFailureDoesNot() {
        var call = CallLifecycle()
        let first = UUID()
        call.reduce(.begin(first))
        XCTAssertTrue(call.reduce(.rejectedBeforeDial(first)))
        XCTAssertEqual(call.state, .ended(first, .rejectedBeforeDial))
        XCTAssertTrue(call.canStartNewCall)
        let second = UUID()
        call.reduce(.begin(second))
        call.reduce(.requestOutcomeUnknown(second))
        XCTAssertFalse(call.canStartNewCall)
        XCTAssertTrue(call.reduce(.connected(second)))
        XCTAssertEqual(call.state, .connected(second))
    }

    func testRouteCapabilitiesMakeAudioGapExplicit() {
        let relay = CallRoute.phoneRelay.capabilities
        XCTAssertTrue(relay.supportsDialHandoff)
        XCTAssertFalse(relay.supportsProgrammaticCalling)
        XCTAssertFalse(relay.supportsProgrammaticAudio)
        XCTAssertFalse(relay.canObserveConnection)
        XCTAssertFalse(relay.canEndCall)

        let service = CallRoute.service.capabilities
        XCTAssertTrue(service.requiresServiceConfiguration)
        XCTAssertTrue(service.supportsProgrammaticAudio)
        XCTAssertTrue(service.canObserveConnection)
        XCTAssertTrue(service.canEndCall)
    }
}
