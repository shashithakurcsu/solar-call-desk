@preconcurrency import AVFoundation

/// AVFoundation invokes these callbacks outside MainActor. Create them in an explicitly
/// nonisolated context before Objective-C callback conversion can erase isolation metadata.
enum AudioCallbackBridge {
    nonisolated static func capture(_ processor: CaptureConverter) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { @Sendable buffer, _ in
            // Borrowed tap buffers are consumed synchronously; no buffer crosses an actor hop.
            processor.consume(buffer)
        }
    }
    nonisolated static func playback(_ completed: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { @Sendable _ in
            Task { @MainActor in completed() }
        }
    }
}
