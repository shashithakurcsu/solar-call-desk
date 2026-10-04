@preconcurrency import AVFoundation

/// The explicit UI/start action is the only caller permitted to request access.
@MainActor public enum MicrophoneAuthorization {
    public static func authorize(status: AVAuthorizationStatus,
                                 request: () async -> Bool) async throws -> Bool {
        try Task.checkCancellation()
        let granted: Bool
        switch status {
        case .authorized: granted = true
        case .notDetermined: granted = await request()
        default: granted = false
        }
        try Task.checkCancellation()
        return granted
    }
}
