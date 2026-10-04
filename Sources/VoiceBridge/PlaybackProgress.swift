import Foundation

/// Counts completed speech buffers. Network underrun silence cannot advance this progress.
struct PlaybackProgress {
    private(set) var scheduledFrames: Int64 = 0
    private(set) var completedFrames: Int64 = 0
    var queuedFrames: Int64 { scheduledFrames - completedFrames }
    var playedFrames: Int64 { completedFrames }
    mutating func schedule(_ frames: Int64) throws {
        guard frames > 0, queuedFrames + frames <= 240_000 else { throw VoiceBridgeError.queueOverflow("Hardware playback queue exceeded its safety bound: queued=\(queuedFrames)frames, incoming=\(frames)frames, limit=240000frames at 24kHz.") }
        scheduledFrames += frames
    }
    mutating func complete(_ frames: Int64) { completedFrames += min(max(0, frames), queuedFrames) }
    mutating func reset() { scheduledFrames = 0; completedFrames = 0 }
}
