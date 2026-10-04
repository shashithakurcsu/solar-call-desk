import Foundation

@MainActor private final class MemoryPreferences: VoicePreferenceStore {
    var strings: [String: String] = [:]
    var flags: [String: Bool] = [:]
    func string(forKey key: String) -> String? { strings[key] }
    func bool(forKey key: String) -> Bool { flags[key] ?? false }
    func set(_ value: String?, forKey key: String) { strings[key] = value }
    func set(_ value: Bool, forKey key: String) { flags[key] = value }
}

@MainActor private final class MemoryCredentials: VoiceCredentialStore {
    var value: String?
    var reads = 0, saves = 0, deletes = 0
    var readError: Error?, saveError: Error?, deleteError: Error?
    var holdRead = false
    var heldRead: CheckedContinuation<String?, Error>?
    func read() async throws -> String? {
        reads += 1
        if holdRead { return try await withCheckedThrowingContinuation { heldRead = $0 } }
        if let readError { throw readError }
        return value
    }
    func save(_ key: String) async throws {
        saves += 1
        if let saveError { throw saveError }
        value = key
    }
    func delete() async throws {
        deletes += 1
        if let deleteError { throw deleteError }
        value = nil
    }
    func releaseRead(_ value: String?) {
        let pending = heldRead; heldRead = nil; holdRead = false
        pending?.resume(returning: value)
    }
}

@main private struct VoicePersistenceSelfCheck {
    @MainActor static func main() async {
        await optOutAndStableIdentity()
        restorationRejectsMissingAmbiguousAndWrongDirection()
        await explicitConsentAndFailures()
        await failedForgetNeverLoadsOnNextLaunch()
        await delayedReadCannotOverwriteEditingOrForget()
        await errorsAndPreferencesNeverExposeSecret()
        acknowledgementChoicesPersistAndRevokeIndependently()
        externalAcknowledgementMatchesExactRouteAcrossLaunches()
        unavailableRoutesCannotRestoreAcknowledgement()
        invalidOrIncompleteAcknowledgementNeverAuthorizes()
        print("PASS: 10 persistence checks; injected memory stores only, no real preferences or Keychain operations.")
    }
    @MainActor private static func make() -> (MemoryPreferences, MemoryCredentials, VoiceSettingsPersistence) {
        let preferences = MemoryPreferences(), credentials = MemoryCredentials()
        return (preferences, credentials, VoiceSettingsPersistence(preferences: preferences, credentials: credentials))
    }
    private static func device(_ id: UInt32, _ uid: String, input: Int = 2, output: Int = 2) -> AudioDevice {
        AudioDevice(id: id, name: "Synthetic", uid: uid, inputChannels: input, outputChannels: output, isVirtual: true)
    }
    @MainActor private static func optOutAndStableIdentity() async {
        let (preferences, credentials, state) = make()
        let ignored = await state.loadSavedKey()
        precondition(ignored == nil && credentials.reads == 0 && credentials.saves == 0 && credentials.deletes == 0)
        state.saveSelection(inputUID: "stable-input", outputUID: "stable-output", mode: .externalBridge)
        let restored = state.restoreSelection(devices: [device(701, "stable-input"), device(702, "stable-output")])
        precondition(restored.input?.id == 701 && restored.output?.id == 702 && restored.mode == .externalBridge && restored.notice == nil)
        precondition(preferences.strings.count == 3 && preferences.flags.isEmpty)
        precondition(Set(preferences.strings.values) == ["stable-input", "stable-output", "externalBridge"])
    }
    @MainActor private static func restorationRejectsMissingAmbiguousAndWrongDirection() {
        let (preferences, _, state) = make()
        state.saveSelection(inputUID: "input", outputUID: "output", mode: .externalBridge)
        let missing = state.restoreSelection(devices: [device(1, "physical-default")])
        precondition(missing.input == nil && missing.output == nil && missing.notice != nil)
        let duplicates = state.restoreSelection(devices: [device(1, "input"), device(2, "input"), device(3, "output", output: 0)])
        precondition(duplicates.input == nil && duplicates.output == nil && duplicates.notice != nil)
        let wrongInput = state.restoreSelection(devices: [device(1, "input", input: 0), device(2, "output")])
        precondition(wrongInput.input == nil && wrongInput.output?.id == 2)
        // A missing route remains saved so a later inventory can restore it; no fallback is persisted.
        precondition(preferences.strings["voice.savedInputUID.v1"] == "input")
        preferences.strings["voice.savedMode.v1"] = "invalid"
        precondition(state.restoreSelection(devices: []).mode == .rehearsal)
    }
    @MainActor private static func explicitConsentAndFailures() async {
        let (preferences, credentials, state) = make()
        credentials.saveError = VoiceCredentialError.status(operation: "save", code: -25293)
        let failed = await state.saveKeyExplicitly("synthetic-key")
        precondition(!failed && !state.keyOptIn && !preferences.bool(forKey: "voice.keychainOptIn.v1"))
        let ignored = await state.loadSavedKey(); precondition(ignored == nil && credentials.reads == 0)
        credentials.saveError = nil
        let saved = await state.saveKeyExplicitly("synthetic-key")
        precondition(saved && state.keyOptIn && credentials.value == "synthetic-key")
        let future = VoiceSettingsPersistence(preferences: preferences, credentials: credentials)
        credentials.readError = VoiceCredentialError.status(operation: "load", code: -25308)
        let locked = await future.loadSavedKey()
        precondition(locked == nil && credentials.reads == 1 && !future.credentialBusy && future.credentialNotice?.contains("-25308") == true)
        credentials.readError = nil
        let retry = await future.loadSavedKey(); precondition(retry == "synthetic-key" && credentials.reads == 2)
        credentials.saveError = VoiceCredentialError.status(operation: "save", code: -25293)
        let update = await state.saveKeyExplicitly("replacement")
        precondition(!update && state.keyOptIn && credentials.value == "synthetic-key")
    }
    @MainActor private static func failedForgetNeverLoadsOnNextLaunch() async {
        let (preferences, credentials, state) = make()
        let saved = await state.saveKeyExplicitly("synthetic-key"); precondition(saved)
        credentials.deleteError = VoiceCredentialError.status(operation: "delete", code: -25293)
        let deleted = await state.forgetSavedKey()
        precondition(!deleted && !state.keyOptIn && state.forgetFailed && credentials.value == "synthetic-key")
        precondition(state.credentialNotice?.contains("could not be deleted") == true)
        let future = VoiceSettingsPersistence(preferences: preferences, credentials: credentials)
        let ignored = await future.loadSavedKey(); precondition(ignored == nil && credentials.reads == 0)
        credentials.deleteError = nil
        let retried = await state.forgetSavedKey()
        precondition(retried && !state.forgetFailed && credentials.value == nil && credentials.deletes == 2)
    }
    @MainActor private static func delayedReadCannotOverwriteEditingOrForget() async {
        let (_, credentials, state) = make()
        let saved = await state.saveKeyExplicitly("synthetic-key"); precondition(saved)
        var revision = 0
        credentials.holdRead = true
        let load = Task { @MainActor in await state.loadSavedKey(unedited: { revision == 0 }) }
        while credentials.heldRead == nil { await Task.yield() }
        revision = 1
        credentials.releaseRead("synthetic-key")
        let edited = await load.value; precondition(edited == nil && state.credentialNotice?.contains("you edited") == true)
        credentials.holdRead = true
        let stale = Task { @MainActor in await state.loadSavedKey() }
        while credentials.heldRead == nil { await Task.yield() }
        let forgotten = await state.forgetSavedKey(); precondition(forgotten && !state.keyOptIn)
        credentials.releaseRead("synthetic-key")
        let oldValue = await stale.value
        precondition(oldValue == nil && !state.credentialBusy && state.credentialNotice?.contains("Forgot") == true)
    }
    @MainActor private static func errorsAndPreferencesNeverExposeSecret() async {
        let (preferences, credentials, state) = make()
        let secret = "synthetic-secret-do-not-persist-in-preferences"
        let saved = await state.saveKeyExplicitly(secret); precondition(saved)
        state.saveSelection(inputUID: "input", outputUID: "output", mode: .rehearsal)
        precondition(!String(describing: preferences.strings).contains(secret) && !String(describing: preferences.flags).contains(secret))
        precondition(preferences.flags.count == 1 && preferences.strings.count == 3)
        credentials.readError = NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        let value = await state.loadSavedKey()
        precondition(value == nil && state.credentialNotice?.contains(secret) == false)
        let rejected = await state.saveKeyExplicitly("bad key")
        precondition(!rejected && credentials.saves == 1)
    }
    @MainActor private static func acknowledgementChoicesPersistAndRevokeIndependently() {
        let (preferences, credentials, state) = make()
        precondition(!state.dataAcknowledged && !state.keyOptIn)
        // Existing saved-key consent is not API audio/charges consent.
        preferences.flags["voice.keychainOptIn.v1"] = true
        let keyOptedIn = VoiceSettingsPersistence(preferences: preferences, credentials: credentials)
        precondition(keyOptedIn.keyOptIn && !keyOptedIn.dataAcknowledged)
        state.saveDataAcknowledgement(true)
        let accepted = VoiceSettingsPersistence(preferences: preferences, credentials: credentials)
        precondition(accepted.dataAcknowledged)
        accepted.saveDataAcknowledgement(false)
        let revoked = VoiceSettingsPersistence(preferences: preferences, credentials: credentials)
        precondition(!revoked.dataAcknowledged && preferences.flags["voice.apiAudioChargesAcknowledged.v1"] == false)
        revoked.saveExternalRoutingAcknowledgement(true, inputUID: "input", outputUID: "output", mode: .externalBridge)
        precondition(!revoked.dataAcknowledged && revoked.keyOptIn)
        precondition(credentials.reads == 0 && credentials.saves == 0 && credentials.deletes == 0)
    }
    @MainActor private static func externalAcknowledgementMatchesExactRouteAcrossLaunches() {
        let (preferences, credentials, state) = make()
        state.saveSelection(inputUID: "input", outputUID: "output", mode: .externalBridge)
        precondition(!state.externalRoutingAcknowledged(inputUID: "input", outputUID: "output", mode: .externalBridge))
        state.saveExternalRoutingAcknowledgement(true, inputUID: "input", outputUID: "output", mode: .externalBridge)
        let future = VoiceSettingsPersistence(preferences: preferences, credentials: credentials)
        let restored = future.restoreSelection(devices: [device(701, "input"), device(702, "output")])
        precondition(future.externalRoutingAcknowledged(inputUID: restored.input?.uid, outputUID: restored.output?.uid, mode: restored.mode))
        precondition(!future.externalRoutingAcknowledged(inputUID: "other-input", outputUID: "output", mode: .externalBridge))
        precondition(!future.externalRoutingAcknowledged(inputUID: "input", outputUID: "other-output", mode: .externalBridge))
        precondition(!future.externalRoutingAcknowledged(inputUID: "output", outputUID: "input", mode: .externalBridge))
        precondition(!future.externalRoutingAcknowledged(inputUID: "input", outputUID: "output", mode: .rehearsal))
        // Selecting/refreshing a different route must not manufacture or revoke an explicit choice.
        future.saveSelection(inputUID: "different-input", outputUID: "different-output", mode: .externalBridge)
        precondition(!future.externalRoutingAcknowledged(inputUID: "different-input", outputUID: "different-output", mode: .externalBridge))
        future.saveSelection(inputUID: "input", outputUID: "output", mode: .externalBridge)
        precondition(future.externalRoutingAcknowledged(inputUID: "input", outputUID: "output", mode: .externalBridge))
        future.saveExternalRoutingAcknowledgement(true, inputUID: "different-input", outputUID: "different-output", mode: .externalBridge)
        precondition(!future.externalRoutingAcknowledged(inputUID: "input", outputUID: "output", mode: .externalBridge))
        precondition(future.externalRoutingAcknowledged(inputUID: "different-input", outputUID: "different-output", mode: .externalBridge))
        future.saveDataAcknowledgement(true)
        future.saveExternalRoutingAcknowledgement(false, inputUID: "different-input", outputUID: "different-output", mode: .externalBridge)
        let revoked = VoiceSettingsPersistence(preferences: preferences, credentials: credentials)
        precondition(!revoked.externalRoutingAcknowledged(inputUID: "different-input", outputUID: "different-output", mode: .externalBridge))
        precondition(revoked.dataAcknowledged && preferences.flags["voice.externalRoutingAcknowledged.v1"] == false)
        precondition(credentials.reads == 0 && credentials.saves == 0 && credentials.deletes == 0)
    }
    @MainActor private static func unavailableRoutesCannotRestoreAcknowledgement() {
        let (_, credentials, state) = make()
        state.saveSelection(inputUID: "input", outputUID: "output", mode: .externalBridge)
        state.saveExternalRoutingAcknowledgement(true, inputUID: "input", outputUID: "output", mode: .externalBridge)
        let inventories = [
            [device(1, "default"), device(2, "output")],
            [device(1, "input"), device(2, "input"), device(3, "output")],
            [device(1, "input", input: 0), device(2, "output")],
            [device(1, "input"), device(2, "output", output: 0)],
        ]
        for devices in inventories {
            let restored = state.restoreSelection(devices: devices)
            precondition(!state.externalRoutingAcknowledged(inputUID: restored.input?.uid, outputUID: restored.output?.uid, mode: restored.mode))
        }
        let returned = state.restoreSelection(devices: [device(901, "input"), device(902, "output")])
        precondition(state.externalRoutingAcknowledged(inputUID: returned.input?.uid, outputUID: returned.output?.uid, mode: returned.mode))
        precondition(credentials.reads == 0 && credentials.saves == 0 && credentials.deletes == 0)
    }
    @MainActor private static func invalidOrIncompleteAcknowledgementNeverAuthorizes() {
        let (preferences, credentials, state) = make()
        // A flag by itself, such as an incomplete preference record, cannot authorize a route.
        preferences.flags["voice.externalRoutingAcknowledged.v1"] = true
        precondition(!state.externalRoutingAcknowledged(inputUID: "input", outputUID: "output", mode: .externalBridge))
        let invalidRoutes: [(String?, String?, VoiceBridgeMode)] = [
            (nil, "output", .externalBridge), ("input", nil, .externalBridge),
            ("", "output", .externalBridge), ("input", "", .externalBridge),
            ("same", "same", .externalBridge), ("input", "output", .rehearsal),
        ]
        for (input, output, mode) in invalidRoutes {
            state.saveExternalRoutingAcknowledgement(true, inputUID: input, outputUID: output, mode: mode)
            precondition(!state.externalRoutingAcknowledged(inputUID: input, outputUID: output, mode: mode))
            precondition(preferences.flags["voice.externalRoutingAcknowledged.v1"] == false)
        }
        state.saveExternalRoutingAcknowledgement(true, inputUID: "input", outputUID: "output", mode: .externalBridge)
        preferences.strings["voice.acknowledgedMode.v1"] = "invalid"
        precondition(!state.externalRoutingAcknowledged(inputUID: "input", outputUID: "output", mode: .externalBridge))
        precondition(!state.dataAcknowledged && !state.keyOptIn)
        precondition(credentials.reads == 0 && credentials.saves == 0 && credentials.deletes == 0)
    }
}
