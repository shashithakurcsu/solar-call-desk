import AVFoundation
import AudioToolbox

/// Selects a Float32 client representation without changing the device's sample rate or channel count.
enum AudioClientFormat {
    static func make(hardware: AVAudioFormat, sampleRate: Double? = nil) throws -> AVAudioFormat {
        let rate = sampleRate ?? hardware.sampleRate
        guard hardware.channelCount > 0, hardware.channelCount <= 64,
              hardware.sampleRate.isFinite, hardware.sampleRate > 0, rate.isFinite, rate > 0 else {
            throw VoiceBridgeError.route("Cannot configure an audio client for \(hardware).")
        }
        if hardware.channelLayout == nil, hardware.channelCount <= 2,
           let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: hardware.channelCount, interleaved: false) { return format }
        // The channel-count initializer only supports mono/stereo. Preserve the device layout
        // when available; explicit discrete order handles a multichannel bus without a layout.
        guard let layout = hardware.channelLayout ?? AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.channelCount) else {
            throw VoiceBridgeError.route("Cannot represent \(hardware.channelCount) audio channels.")
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
    }
}

/// Speech is mono PCM on the wire. Duplicate it onto the first pair and silence remaining bus channels.
enum SpeechPlaybackBuffer {
    static func make(data: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let samples = try PCM16.floats(data)
        guard !samples.isEmpty, samples.count <= 240_000, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { throw VoiceBridgeError.route("Cannot allocate speech playback buffer.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            if channel < 2 {
                samples.withUnsafeBufferPointer { channels[channel].update(from: $0.baseAddress!, count: samples.count) }
            } else { channels[channel].initialize(repeating: 0, count: samples.count) }
        }
        return buffer
    }
}
