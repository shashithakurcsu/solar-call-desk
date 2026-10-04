import Foundation
import Security
import Dispatch

/// Compatible macOS login Keychain. No custom ACL, access group, shared entitlement,
/// Data Protection override, synchronization, or process-wide interaction setting.
/// Standard current-app access controls may prompt after an ad-hoc signed update.
public final class LocalKeychainCredentialStore: VoiceCredentialStore {
    private let service = "com.solarcalldesk.voice.openai.local.v1"
    private let account = "openai-api-key"
    private let queue = DispatchQueue(label: "SolarCallDesk.Keychain")
    public init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    public func read() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                var request = query
                request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(request as CFDictionary, &result)
                if status == errSecItemNotFound { continuation.resume(returning: nil); return }
                guard status == errSecSuccess else { continuation.resume(throwing: VoiceCredentialError.status(operation: "load", code: status)); return }
                guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                    continuation.resume(throwing: VoiceCredentialError.invalidStoredValue); return
                }
                continuation.resume(returning: key)
            }
        }
    }
    public func save(_ key: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let value = Data(key.utf8)
                var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
                if status == errSecItemNotFound {
                    var item = query; item[kSecValueData as String] = value
                    item[kSecAttrLabel as String] = "Solar Call Desk OpenAI API key"
                    status = SecItemAdd(item as CFDictionary, nil)
                }
                if status == errSecSuccess { continuation.resume() }
                else { continuation.resume(throwing: VoiceCredentialError.status(operation: "save", code: status)) }
            }
        }
    }
    public func delete() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let status = SecItemDelete(query as CFDictionary)
                if status == errSecSuccess || status == errSecItemNotFound { continuation.resume() }
                else { continuation.resume(throwing: VoiceCredentialError.status(operation: "delete", code: status)) }
            }
        }
    }
}
