import Foundation

struct HALToneMetrics: Equatable {
    let ownRMS: Double, foreignRMS: Double, correlation: Double, gain: Double, leakageRatio: Double
    let analyzedFrames: Int
    let passed: Bool
}

/// Each bus carries its own tone simultaneously. Measure foreign-frequency energy on THIS bus.
/// One-second windows make integer-Hz test tones orthogonal; this is not the silent-peer classifier.
enum HALToneClassifier {
    static func measure(_ samples: [Float], frequency: Double, foreignFrequency: Double) -> HALToneMetrics {
        let rms = LoopbackClassifier.rms(samples)
        let own = coherentRMS(samples, frequency: frequency), foreign = coherentRMS(samples, frequency: foreignFrequency)
        let correlation = rms > 0 ? min(1, own / rms) : 0
        let gain = own / (LoopbackClassifier.amplitude / sqrt(2))
        let ratio = own > 0 ? foreign / own : .infinity
        let validFrequencies = frequency.isFinite && foreignFrequency.isFinite && frequency > 0 && foreignFrequency > 0
            && frequency < 12_000 && foreignFrequency < 12_000 && frequency != foreignFrequency
        let passed = validFrequencies && samples.count == 24_000 && rms.isFinite && own.isFinite && foreign.isFinite
            && correlation >= 0.98 && gain >= 0.8 && gain <= 1.2 && ratio <= 0.03 && foreign <= 0.0005
        return HALToneMetrics(ownRMS: rms, foreignRMS: foreign, correlation: correlation, gain: gain,
            leakageRatio: ratio, analyzedFrames: samples.count, passed: passed)
    }
    private static func coherentRMS(_ samples: [Float], frequency: Double) -> Double {
        guard frequency.isFinite, !samples.isEmpty else { return .infinity }
        var sine = 0.0, cosine = 0.0
        for (index, value) in samples.enumerated() {
            let phase = Double(index) * 2 * .pi * frequency / 24_000
            sine += Double(value) * sin(phase); cosine += Double(value) * cos(phase)
        }
        return hypot(sine, cosine) * sqrt(2) / Double(samples.count)
    }
}
