import Foundation
import Darwin
import CallCore
import CallAutomation

@MainActor final class FakeRuntime: SambhaCallRuntime {
    var sambhaBusy = false, sambhaVoiceReady = false
    var sambhaVoiceFailure: String?
    var sambhaSetupStatus: [String: String] = ["microphone": "authorized", "unattended_calling": "unavailable"]
    var validationFailure = false, startupFailure = false, hold = false, becomeReady = true
    var starts = 0, stops = 0, dials = 0, confirms = 0
    var inspectedTargets: [String?] = [], inspectionCancels = 0
    var sambhaPhoneControlProbeSnapshot: [String: Any] { ["state": "synthetic", "phone_status": "unknown"] }
    func sambhaStartPhoneControlProbe(expectedNumber: String?) { inspectedTargets.append(expectedNumber) }
    func sambhaCancelPhoneControlProbe() { inspectionCancels += 1 }
    var instructions = "", numbers: [String] = []
    var continuation: CheckedContinuation<Void, Never>?
    var visualConfirms = 0, visualEnds = 0, visualCancelled = false
    var visualCallPosted = false, closePanel = false, holdConfirmation = false, holdHangup = false
    var confirmationContinuation: CheckedContinuation<Void, Never>?
    var hangupContinuation: CheckedContinuation<Void, Never>?
    func sambhaPreparePhoneControl(jobID: UUID, number: String) throws {
        visualCancelled = false; visualCallPosted = false
    }
    func sambhaConfirmPhoneCall() async -> SambhaPhoneReceipt {
        visualConfirms += 1
        if holdConfirmation { await withCheckedContinuation { confirmationContinuation = $0 } }
        if !visualCancelled { visualCallPosted = true }
        return .init(callClickPosted: visualCallPosted, hangupPanelClosed: false, status: "Synthetic confirmation")
    }
    func sambhaEndPhoneCall() async -> SambhaPhoneReceipt {
        visualEnds += 1
        if holdHangup { await withCheckedContinuation { hangupContinuation = $0 } }
        if closePanel { sambhaBusy = false }
        return .init(callClickPosted: visualCallPosted, hangupPanelClosed: closePanel, status: "Synthetic hangup")
    }
    func sambhaCancelPhoneControl() { visualCancelled = true }
    func releaseConfirmation() { let pending = confirmationContinuation; confirmationContinuation = nil; pending?.resume() }
    func releaseHangup() { let pending = hangupContinuation; hangupContinuation = nil; pending?.resume() }
    func sambhaValidateStart() throws { if validationFailure { throw failure("Missing synthetic setup.") } }
    func sambhaStartVoice(instructions: String) async throws {
        starts += 1; self.instructions = instructions
        if startupFailure { throw failure("Synthetic configuration failed.") }
        if hold { await withCheckedContinuation { continuation = $0 } }
        if !hold && becomeReady { sambhaVoiceReady = true }
    }
    func release() { hold = false; sambhaVoiceReady = true; let value = continuation; continuation = nil; value?.resume() }
    func sambhaStopVoice() { stops += 1; sambhaVoiceReady = false }
    func sambhaHandoff(number: PhoneNumber, recipient: String) throws { dials += 1; numbers.append(number.normalized); sambhaBusy = true }
    func sambhaConfirmEnded() { confirms += 1; sambhaBusy = false }
    func sambhaInstructions(message: String, recipient: String) -> String { recipient + "\n" + message }
}
func check(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) {
    do { let passed = try value(); precondition(passed, "Synthetic check failed", file: file, line: line) }
    catch { preconditionFailure("Synthetic check threw: \(error)", file: file, line: line) }
}
func failure(_ message: String) -> NSError { NSError(domain: "SyntheticOnly", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
@MainActor func request(_ controller: SambhaJobController, _ name: String, _ id: UUID? = nil, fields: [String: Any] = [:]) throws -> [String: Any] {
    var command = fields; command["command"] = name; if let id { command["job_id"] = id.uuidString }
    return try JSONSerialization.jsonObject(with: controller.handle(JSONSerialization.data(withJSONObject: command))) as! [String: Any]
}
func payload(_ message: String = "Please ask whether Friday works.") -> [String: Any] { ["recipient": "Synthetic recipient", "number": "+14155550123", "message": message] }
@MainActor func settle() async { for _ in 0..<30 { await Task.yield() } }

@main struct SambhaSelfCheck {
    @MainActor static func main() async throws {
        try await validationAndIdempotency()
        try await configurationAndReadinessFailure()
        try await successAndTranscriptAssociation()
        try await stopDisableAndStaleCallback()
        try await timeoutAndPhoneLock()
        try await boundedEscapedResult()
        try await actualPrivateIPC()
        try await unsafeDirectoryRejected()
        try setupStatusIsReadOnly()
        try phoneInspectionCommandsAreReadOnly()
        try await automaticPhoneSequence()
        try await cancelledConfirmationCannotClickLater()
        try await ambiguousEndRemainsLocked()
        try await userEndDuringHangupKeepsItsEvidence()
        print("PASS: 14 Sambha command/IPC checks; fake runtime only, no voice/audio/Phone/API actions.")
    }
    @MainActor static func userEndDuringHangupKeepsItsEvidence() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime)
        runtime.holdHangup = true; runtime.closePanel = true; controller.enable(); let id = UUID()
        _ = try request(controller, "prepare", id, fields: payload()); _ = try request(controller, "start", id); await settle()
        _ = try request(controller, "stop-voice", id); await settle()
        check(runtime.hangupContinuation != nil)
        _ = try request(controller, "report-ended", id, fields: ["user_confirmed": true])
        check(controller.hasReservedWork && runtime.confirms == 1)
        runtime.releaseHangup(); await settle()
        let result = try request(controller, "result", id)
        check(result["phase"] as? String == "ended_user_reported")
        check(result["phone_end_user_reported"] as? Bool == true && result["phone_hangup_ui_closed"] as? Bool == false)
        check(!controller.hasReservedWork && runtime.visualEnds == 1)
        check(try request(controller, "prepare", UUID(), fields: payload())["ok"] as? Bool == true)
        controller.disable()
    }
    @MainActor static func automaticPhoneSequence() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime)
        runtime.closePanel = true; controller.enable(); let id = UUID()
        _ = try request(controller, "prepare", id, fields: payload())
        _ = try request(controller, "start", id); await settle()
        check(runtime.visualConfirms == 1 && runtime.visualCallPosted && runtime.dials == 1)
        for _ in 0..<4 { _ = try request(controller, "start", id); _ = try request(controller, "status") }
        check(runtime.visualConfirms == 1 && runtime.visualEnds == 0)
        controller.voiceStopped(error: nil); await settle()
        let result = try request(controller, "result", id)
        check(result["phase"] as? String == "ended_phone_ui")
        check(result["phone_status"] as? String == "hangup_requested_panel_closed")
        check(result["phone_end_required"] as? Bool == false)
        check(result["phone_end_user_reported"] as? Bool == false && result["carrier_status"] as? String == "unknown")
        _ = try request(controller, "stop-voice", id); _ = try request(controller, "report-ended", id, fields: ["user_confirmed": true])
        check(runtime.visualEnds == 1 && runtime.confirms == 0)
        check(try request(controller, "prepare", UUID(), fields: payload())["ok"] as? Bool == true)
        controller.disable()
    }
    @MainActor static func cancelledConfirmationCannotClickLater() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime)
        runtime.holdConfirmation = true; controller.enable(); let id = UUID()
        _ = try request(controller, "prepare", id, fields: payload()); _ = try request(controller, "start", id); await settle()
        check(runtime.confirmationContinuation != nil && runtime.dials == 1)
        _ = try request(controller, "stop-voice", id); await settle()
        check(controller.hasReservedWork && runtime.visualEnds == 0)
        check(try request(controller, "prepare", UUID(), fields: payload())["ok"] as? Bool == false)
        runtime.releaseConfirmation(); await settle()
        check(!runtime.visualCallPosted && runtime.visualEnds == 1 && !controller.ownsVoice)
        check(try request(controller, "status")["phase"] as? String == "phone_end_unverified")
        controller.disable()
    }
    @MainActor static func ambiguousEndRemainsLocked() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime)
        controller.enable(); let id = UUID()
        _ = try request(controller, "prepare", id, fields: payload()); _ = try request(controller, "start", id); await settle()
        controller.voiceStopped(error: "Synthetic failure"); await settle()
        for _ in 0..<4 { _ = try request(controller, "stop-voice", id) }
        _ = try request(controller, "result", id)
        check(runtime.visualEnds == 1)
        check(try request(controller, "prepare", UUID(), fields: payload())["ok"] as? Bool == false)
        controller.disable(); controller.enable(); await settle()
        check(runtime.visualEnds == 1 && runtime.dials == 1)
        controller.disable()
    }
    @MainActor static func phoneInspectionCommandsAreReadOnly() throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime)
        check(try request(controller, "inspect-phone-controls")["ok"] as? Bool == false)
        check(runtime.inspectedTargets.isEmpty)
        controller.enable()
        check(try request(controller, "inspect-phone-controls", fields: ["expected_number": "4155550123"])["ok"] as? Bool == false)
        check(try request(controller, "inspect-phone-controls", fields: ["expected_number": true])["ok"] as? Bool == false)
        check(runtime.inspectedTargets.isEmpty)
        runtime.validationFailure = true // Read-only inspection needs no API/audio configuration.
        check(try request(controller, "inspect-phone-controls")["ok"] as? Bool == true)
        check(runtime.inspectedTargets.count == 1 && runtime.inspectedTargets[0] == nil)
        check(try request(controller, "inspect-phone-controls", fields: ["expected_number": "+14155550123"])["ok"] as? Bool == true)
        check(runtime.inspectedTargets.count == 2 && runtime.inspectedTargets[1] == "+14155550123")
        let result = try request(controller, "phone-controls-result")
        check((result["phone_controls_probe"] as? [String: String])?["phone_status"] == "unknown")
        check(result["job_id"] == nil && result["phone_status"] as? String == "unknown")
        _ = try request(controller, "cancel-phone-inspection")
        check(runtime.inspectionCancels == 1 && runtime.inspectedTargets.count == 2)
        check(runtime.starts == 0 && runtime.stops == 0 && runtime.dials == 0 && runtime.confirms == 0)
        controller.disable()
    }
    @MainActor static func setupStatusIsReadOnly() throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime)
        controller.enable()
        let result = try request(controller, "status")
        let setup = result["setup"] as? [String: String]
        check(setup?["microphone"] == "authorized")
        check(setup?["unattended_calling"] == "unavailable")
        check(result["phone_status"] as? String == "unknown")
        check(runtime.starts == 0 && runtime.stops == 0 && runtime.dials == 0 && runtime.confirms == 0)
        runtime.sambhaSetupStatus["microphone"] = "denied"
        check((try request(controller, "status")["setup"] as? [String: String])?["microphone"] == "denied")
        controller.disable()
    }
    @MainActor static func validationAndIdempotency() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: FakeRuntime())
        // The controller has a weak runtime: retain it in every real/fake owner.
        let owned = SambhaJobController(runtime: runtime); owned.enable(); let id = UUID()
        check(try request(owned, "prepare", id, fields: payload())["ok"] as? Bool == true)
        let same = try request(owned, "prepare", id, fields: payload()); check(same["message"] as? String == payload()["message"] as? String)
        check(try request(owned, "prepare", id, fields: payload("Different"))["ok"] as? Bool == false)
        check(try request(owned, "start")["ok"] as? Bool == false)
        check(try request(owned, "result", UUID())["ok"] as? Bool == false)
        check(try request(owned, "prepare", UUID(), fields: payload())["ok"] as? Bool == false)
        _ = try request(owned, "result", id)
        check(try request(owned, "prepare", UUID(), fields: payload())["ok"] as? Bool == false)
        _ = try request(owned, "stop-voice", id); _ = try request(owned, "result", id)
        _ = try request(owned, "start", id); await settle(); check(runtime.starts == 0 && runtime.dials == 0)
        var bad = payload(); bad["number"] = "14155550123"
        check(try request(owned, "prepare", UUID(), fields: bad)["ok"] as? Bool == false)
        bad = payload(); bad["message"] = String(repeating: "x", count: 16_385)
        check(try request(owned, "prepare", UUID(), fields: bad)["ok"] as? Bool == false)
        let next = UUID(); check(try request(owned, "prepare", next, fields: payload())["ok"] as? Bool == true)
        check(try request(owned, "prepare", id, fields: payload())["ok"] as? Bool == false)
        _ = try request(owned, "report-ended", next, fields: ["user_confirmed": true])
        _ = try request(owned, "start", next); await settle()
        check(runtime.starts == 0 && runtime.dials == 0)
        controller.disable(); owned.disable(); await settle()
    }
    @MainActor static func configurationAndReadinessFailure() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime); controller.enable(); let id = UUID()
        _ = try request(controller, "prepare", id, fields: payload()); runtime.validationFailure = true
        check(try request(controller, "start", id)["ok"] as? Bool == false)
        runtime.validationFailure = false; _ = try request(controller, "start", id)
        check(runtime.starts == 0 && runtime.dials == 0)
        _ = try request(controller, "result", id); let next = UUID(); _ = try request(controller, "prepare", next, fields: payload())
        runtime.startupFailure = true; _ = try request(controller, "start", next); await settle()
        check(runtime.starts == 1 && runtime.dials == 0 && runtime.stops == 1)
        check(try request(controller, "result", next)["phase"] as? String == "start_failed")
        controller.disable()
    }
    @MainActor static func successAndTranscriptAssociation() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime); controller.enable(); let id = UUID()
        controller.recordTranscript(role: "INPUT", text: "Old unrelated session")
        _ = try request(controller, "prepare", id, fields: payload("Exact supplied message."))
        _ = try request(controller, "start", id); await settle()
        for _ in 0..<10 { _ = try request(controller, "start", id) }
        check(runtime.starts == 1 && runtime.dials == 1 && runtime.numbers == ["+14155550123"])
        controller.recordTranscript(role: "INPUT", text: "Friday works."); controller.recordTranscript(role: "AI", text: "Thank you.")
        _ = try request(controller, "stop-voice", id)
        controller.recordTranscript(role: "INPUT", text: "Unrelated later session")
        let result = try request(controller, "result", id), transcripts = result["transcripts"] as! [[String: Any]]
        check(transcripts.count == 2 && transcripts[0]["text"] as? String == "Friday works.")
        check(transcripts[1]["evidence"] as? String == "AI-generated speech; recipient hearing unverified.")
        check(result["phone_status"] as? String == "unknown" && result["phone_end_required"] as? Bool == true)
        check(try request(controller, "report-ended", id)["ok"] as? Bool == false)
        _ = try request(controller, "report-ended", id, fields: ["user_confirmed": true]); await settle(); check(runtime.confirms == 1)
        runtime.sambhaBusy = true // An unrelated later manual handoff cannot be reconciled by duplicate old commands.
        _ = try request(controller, "report-ended", id, fields: ["user_confirmed": true]); check(runtime.confirms == 1 && runtime.sambhaBusy)
        runtime.sambhaBusy = false
        _ = try request(controller, "result", id); let next = UUID(); _ = try request(controller, "prepare", next, fields: payload())
        check((try request(controller, "result", next)["transcripts"] as? [[String: Any]])?.isEmpty == true)
        controller.disable()
    }
    @MainActor static func stopDisableAndStaleCallback() async throws {
        for disable in [false, true] {
            let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime); runtime.hold = true; controller.enable(); let id = UUID()
            _ = try request(controller, "prepare", id, fields: payload()); _ = try request(controller, "start", id); await settle()
            check(runtime.continuation != nil)
            if disable { controller.disable(); controller.enable() } else { _ = try request(controller, "stop-voice", id) }
            _ = try request(controller, "result", id); let next = UUID(); _ = try request(controller, "prepare", next, fields: payload())
            runtime.release(); await settle(); check(runtime.dials == 0 && runtime.stops == 1)
            check(try request(controller, "status")["job_id"] as? String == next.uuidString)
            controller.disable()
        }
    }
    @MainActor static func timeoutAndPhoneLock() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime, readinessSeconds: 0.01, maximumVoiceSeconds: 0.2)
        runtime.hold = true; runtime.becomeReady = false; controller.enable(); let id = UUID(); _ = try request(controller, "prepare", id, fields: payload())
        _ = try request(controller, "start", id); await settle(); runtime.hold = false
        // Release without setting readiness so the configuration timeout path is exercised.
        let continuation = runtime.continuation; runtime.continuation = nil; continuation?.resume()
        try await Task.sleep(for: .milliseconds(80)); check(runtime.dials == 0 && runtime.stops == 1)
        _ = try request(controller, "result", id); let next = UUID(); _ = try request(controller, "prepare", next, fields: payload())
        runtime.becomeReady = true; _ = try request(controller, "start", next); await settle(); check(runtime.dials == 1)
        try await Task.sleep(for: .milliseconds(250)); check(!controller.ownsVoice)
        _ = try request(controller, "result", next)
        check(try request(controller, "prepare", UUID(), fields: payload())["ok"] as? Bool == false)
        check(runtime.confirms == 0); controller.disable()
    }
    @MainActor static func boundedEscapedResult() async throws {
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime); controller.enable(); let id = UUID()
        _ = try request(controller, "prepare", id, fields: payload(String(repeating: "\0", count: 8_000)))
        _ = try request(controller, "start", id); await settle()
        for _ in 0..<100 { controller.recordTranscript(role: "INPUT", text: String(repeating: "\0", count: 4_096)) }
        _ = try request(controller, "stop-voice", id)
        let command: [String: Any] = ["command": "result", "job_id": id.uuidString]
        let resultData = controller.handle(try JSONSerialization.data(withJSONObject: command))
        check(resultData.count > 524_288 && resultData.count < 2_097_152)
        let result = try JSONSerialization.jsonObject(with: resultData) as! [String: Any]
        check(result["transcripts_truncated"] as? Bool == true); controller.disable()
    }
    @MainActor static func actualPrivateIPC() async throws {
        let base = "/tmp/solar-sambha-test-" + UUID().uuidString, path = base + "/control.sock"
        let runtime = FakeRuntime(), controller = SambhaJobController(runtime: runtime); controller.enable()
        let server = LocalCommandServer(path: path) { data in controller.handle(data) }
        try await server.start(); defer { server.stopAndWait(); try? FileManager.default.removeItem(atPath: base) }
        var info = stat(); check(lstat(base, &info) == 0 && info.st_mode & 0o777 == 0o700)
        check(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        for _ in 0..<2 {
            let response = try await Task.detached { try exchange(path, Data("{\"command\":\"status\"}\n".utf8)) }.value
            check((try JSONSerialization.jsonObject(with: response) as! [String: Any])["ok"] as? Bool == true)
        }
        let cli = FileManager.default.currentDirectoryPath + "/scripts/solar-call.py", id = UUID().uuidString
        let messagePath = base + "/synthetic-message.txt"
        try Data("Synthetic exact message.".utf8).write(to: URL(fileURLWithPath: messagePath))
        let cliStatusData = try await Task.detached { try runCLI(cli, ["--socket", path, "status"]) }.value
        let cliStatus = try JSONSerialization.jsonObject(with: cliStatusData) as! [String: Any]
        check(cliStatus["ok"] as? Bool == true)
        let cliPrepareData = try await Task.detached { try runCLI(cli, ["--socket", path, "prepare", "--job-id", id, "--recipient", "Synthetic recipient", "--number", "+14155550123", "--message-file", messagePath]) }.value
        let cliPrepare = try JSONSerialization.jsonObject(with: cliPrepareData) as! [String: Any]
        check(cliPrepare["message"] as? String == "Synthetic exact message.")
        let cliResultData = try await Task.detached { try runCLI(cli, ["--socket", path, "result", "--job-id", id]) }.value
        let cliResult = try JSONSerialization.jsonObject(with: cliResultData) as! [String: Any]
        check(cliResult["phase"] as? String == "prepared")
        let malformed = try await Task.detached { try exchange(path, Data("no JSON\n".utf8)) }.value
        check((try JSONSerialization.jsonObject(with: malformed) as! [String: Any])["ok"] as? Bool == false)
        let multi = try await Task.detached { try exchange(path, Data("{}\n{}\n".utf8)) }.value
        check(multi.isEmpty)
        let oversize = try await Task.detached { try exchange(path, Data(repeating: 65, count: 65_538)) }.value
        check(oversize.isEmpty && runtime.starts == 0 && runtime.dials == 0)
        server.stopAndWait(); check(lstat(path, &info) != 0)
        controller.disable()
    }
    @MainActor static func unsafeDirectoryRejected() async throws {
        let base = "/tmp/solar-sambha-unsafe-" + UUID().uuidString; check(mkdir(base, 0o755) == 0); check(chmod(base, 0o755) == 0)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let server = LocalCommandServer(path: base + "/control.sock") { _ in Data("{}".utf8) }
        do { try await server.start(); preconditionFailure("Unsafe directory accepted") } catch {}
        server.stopAndWait()
    }
}

func exchange(_ path: String, _ request: Data) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw failure("Synthetic socket failed") }; defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0), noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.initializeMemory(as: UInt8.self, repeating: 0); $0.copyBytes(from: Array(path.utf8) + [0]) }
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard connected == 0 else { throw failure("Synthetic connect failed") }
    var offset = 0
    while offset < request.count {
        let sent = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), request.count - offset) }
        if sent <= 0 { return Data() }; offset += sent
    }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
    while result.count <= 2_097_153 {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count))
        if let newline = result.firstIndex(of: 10) { return Data(result.prefix(upTo: newline)) }
    }
    return result
}

func runCLI(_ script: String, _ arguments: [String]) throws -> Data {
    let process = Process(), output = Pipe(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script] + arguments
    process.standardOutput = output; process.standardError = errors
    try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw failure("Synthetic Python CLI failed") }
    return data
}
