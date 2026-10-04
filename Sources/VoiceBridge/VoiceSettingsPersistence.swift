import Foundation
import Combine

@MainActor public protocol VoicePreferenceStore: AnyObject {
    func string(forKey: String) -> String?
    func bool(forKey: String) -> Bool
    func set(_ value: String?, forKey: String)
    func set(_ value: Bool, forKey: String)
}
@MainActor public final class UserDefaultsVoicePreferences: VoicePreferenceStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func set(_ value: String?, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}
public protocol VoiceCredentialStore: Sendable {
    func read() async throws -> String?
    func save(_ key: String) async throws
    func delete() async throws
}
public enum VoiceCredentialError: Error, LocalizedError, Sendable {
    case status(operation: String, code: Int32), invalidStoredValue
    public var errorDescription: String? {
        switch self {
        case .status(let operation, let code): "Keychain \(operation) failed (\(code)). macOS may require access approval or an unlocked Keychain."
        case .invalidStoredValue: "The saved Keychain item is not a valid API key. Save a replacement or forget it."
        }
    }
}
public struct RestoredVoiceSelection: Sendable {
    public let mode: VoiceBridgeMode
    public let input: AudioDevice?
    public let output: AudioDevice?
    public let notice: String?
}

/// Preferences contain identifiers, mode, and explicit consent choices only. Secret operations occur only
/// behind explicit save/forget or a previous save's future-load consent.
@MainActor public final class VoiceSettingsPersistence: ObservableObject {
    private enum Keys {
        static let input = "voice.savedInputUID.v1", output = "voice.savedOutputUID.v1"
        static let mode = "voice.savedMode.v1", consent = "voice.keychainOptIn.v1"
        static let dataAcknowledged = "voice.apiAudioChargesAcknowledged.v1"
        static let routesAcknowledged = "voice.externalRoutingAcknowledged.v1"
        static let acknowledgedInput = "voice.acknowledgedInputUID.v1", acknowledgedOutput = "voice.acknowledgedOutputUID.v1"
        static let acknowledgedMode = "voice.acknowledgedMode.v1"
    }
    @Published public private(set) var keyOptIn: Bool
    @Published public private(set) var credentialBusy = false
    @Published public private(set) var credentialNotice: String?
    @Published public private(set) var forgetFailed = false
    private let preferences: any VoicePreferenceStore
    private let credentials: any VoiceCredentialStore
    private var generation = UUID()
    public init(preferences: any VoicePreferenceStore, credentials: any VoiceCredentialStore) {
        self.preferences = preferences; self.credentials = credentials
        keyOptIn = preferences.bool(forKey: Keys.consent)
    }
    public func saveSelection(inputUID: String?, outputUID: String?, mode: VoiceBridgeMode) {
        preferences.set(inputUID, forKey: Keys.input); preferences.set(outputUID, forKey: Keys.output)
        preferences.set(mode.rawValue, forKey: Keys.mode)
    }
    public var dataAcknowledged: Bool { preferences.bool(forKey: Keys.dataAcknowledged) }
    public func saveDataAcknowledgement(_ acknowledged: Bool) {
        preferences.set(acknowledged, forKey: Keys.dataAcknowledged)
    }
    /// The explicit choice belongs to these directional identities, never to device names or IDs.
    public func saveExternalRoutingAcknowledgement(_ acknowledged: Bool, inputUID: String?, outputUID: String?, mode: VoiceBridgeMode) {
        let validRoute = mode == .externalBridge && inputUID?.isEmpty == false && outputUID?.isEmpty == false && inputUID != outputUID
        preferences.set(acknowledged && validRoute, forKey: Keys.routesAcknowledged)
        preferences.set(acknowledged && validRoute ? inputUID : nil, forKey: Keys.acknowledgedInput)
        preferences.set(acknowledged && validRoute ? outputUID : nil, forKey: Keys.acknowledgedOutput)
        preferences.set(acknowledged && validRoute ? mode.rawValue : nil, forKey: Keys.acknowledgedMode)
    }
    public func externalRoutingAcknowledged(inputUID: String?, outputUID: String?, mode: VoiceBridgeMode) -> Bool {
        mode == .externalBridge && inputUID?.isEmpty == false && outputUID?.isEmpty == false && inputUID != outputUID &&
        preferences.bool(forKey: Keys.routesAcknowledged) &&
        preferences.string(forKey: Keys.acknowledgedInput) == inputUID &&
        preferences.string(forKey: Keys.acknowledgedOutput) == outputUID &&
        preferences.string(forKey: Keys.acknowledgedMode) == mode.rawValue
    }
    public func restoreSelection(devices: [AudioDevice]) -> RestoredVoiceSelection {
        let mode = preferences.string(forKey: Keys.mode).flatMap(VoiceBridgeMode.init(rawValue:)) ?? .rehearsal
        var notices: [String] = []
        func match(_ key: String, input: Bool) -> AudioDevice? {
            guard let uid = preferences.string(forKey: key), !uid.isEmpty else { return nil }
            let matches = devices.filter { $0.uid == uid }
            guard matches.count == 1, let device = matches.first,
                  (input ? device.inputChannels : device.outputChannels) > 0 else {
                notices.append("Saved \(input ? "input" : "output") is missing, ambiguous, or unavailable in that direction. Choose it again; no default device was substituted.")
                return nil
            }
            return device
        }
        let input = match(Keys.input, input: true), output = match(Keys.output, input: false)
        return .init(mode: mode, input: input, output: output, notice: notices.isEmpty ? nil : notices.joined(separator: " "))
    }
    public func loadSavedKey(unedited: @escaping @MainActor () -> Bool = { true }) async -> String? {
        guard keyOptIn, !credentialBusy else { return nil }
        credentialBusy = true; let token = UUID(); generation = token
        defer { if generation == token { credentialBusy = false } }
        do {
            let value = try await credentials.read()
            guard generation == token, keyOptIn else { return nil }
            guard let value else { credentialNotice = "No saved key was found. Save a key explicitly or forget the saved-key setting."; return nil }
            guard Self.validKey(value) else { throw VoiceCredentialError.invalidStoredValue }
            guard unedited() else { credentialNotice = "Kept the API key you edited while the saved key was loading."; return nil }
            credentialNotice = "Loaded the saved key from this Mac’s Keychain."
            return value
        } catch {
            if generation == token { credentialNotice = "Could not load the saved key. \(Self.safeError(error)) Use Load saved key to retry." }
            return nil
        }
    }
    @discardableResult public func saveKeyExplicitly(_ key: String) async -> Bool {
        guard !credentialBusy else { return false }
        guard Self.validKey(key) else { credentialNotice = "Enter a valid API key before saving it. No key was saved."; return false }
        credentialBusy = true; let token = UUID(); generation = token
        defer { if generation == token { credentialBusy = false } }
        do {
            try await credentials.save(key)
            guard generation == token else { return false }
            preferences.set(true, forKey: Keys.consent); keyOptIn = true; forgetFailed = false
            credentialNotice = "Saved in this Mac’s local Keychain. Solar will load it on future launches; macOS may ask you to allow access."
            return true
        } catch {
            if generation == token { credentialNotice = "The key was not saved. \(Self.safeError(error))" }
            return false
        }
    }
    /// Opt out before deletion: a locked/denied deletion must not cause another launch to load.
    @discardableResult public func forgetSavedKey() async -> Bool {
        generation = UUID(); let token = generation
        preferences.set(false, forKey: Keys.consent); keyOptIn = false
        credentialBusy = true
        defer { if generation == token { credentialBusy = false } }
        do {
            try await credentials.delete()
            guard generation == token else { return false }
            forgetFailed = false; credentialNotice = "Forgot the saved key. Automatic loading is off."
            return true
        } catch {
            if generation == token {
                forgetFailed = true
                credentialNotice = "Automatic loading is off, but the Keychain item could not be deleted. \(Self.safeError(error)) Retry Forget saved key."
            }
            return false
        }
    }
    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count < 4_096 && !key.contains(where: { $0.isWhitespace || $0.isNewline })
    }
    private static func safeError(_ error: Error) -> String {
        (error as? VoiceCredentialError)?.localizedDescription ?? "Keychain access failed. Unlock it or approve access and retry."
    }
}
