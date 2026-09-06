import AVFoundation

/// File-based loudness, onset, and signed PCM history sampled on the playback clock.
/// Analysis loads the clip into memory; perform it away from the UI/audio render thread.
public struct SpeechEnvelope: Sendable {
    public static let waveformSamples = 512
    public static let waveformDuration: Double = 0.48
    public let levels: [Float]
    public let interval: Double
    public let duration: Double
    private let peaks: [SIMD2<Float>]
    private let peakInterval: Double

    /// Analyze a nonempty audio file supported by AVAudioFile.
    public init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RendererFailure.unavailable("The audio clip is empty.")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw RendererFailure.unavailable("The speech audio format could not be analyzed.")
        }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        let window = max(1,Int(buffer.format.sampleRate*0.01))
        interval = Double(window)/buffer.format.sampleRate
        duration = Double(count)/buffer.format.sampleRate
        var result: [Float] = []
        for first in stride(from: 0, to: count, by: window) {
            let end = min(count,first+window)
            var energy: Float = 0
            for channel in 0..<channelCount {
                for index in first..<end { energy += channels[channel][index]*channels[channel][index] }
            }
            let rms = sqrt(energy/Float((end-first)*channelCount))
            // A quiet gate removes the noise floor; compression gives soft
            // words presence while leaving headroom for stressed syllables.
            result.append(min(1,pow(max(0,rms-0.0015)/0.12,0.65)))
        }
        levels = result
        // Keep signed PCM extrema at 1 ms resolution, separate from the broad
        // RMS envelope used for flash and the original circulating mode.
        let peakWindow = max(1,Int(buffer.format.sampleRate*0.001))
        peakInterval = Double(peakWindow)/buffer.format.sampleRate
        var extrema: [SIMD2<Float>] = []
        for first in stride(from: 0,to: count,by: peakWindow) {
            var low: Float = 0, high: Float = 0
            for channel in 0..<channelCount {
                for index in first..<min(count,first+peakWindow) {
                    low = min(low,channels[channel][index])
                    high = max(high,channels[channel][index])
                }
            }
            extrema.append(SIMD2(-min(1,pow(-low/0.90,0.7)),min(1,pow(high/0.90,0.7))))
        }
        peaks = extrema
    }

    /// Return 512 signed peak pairs, oldest first, covering the latest 480 ms.
    public func waveform(at time: Double) -> [SIMD2<Float>] {
        guard time.isFinite else { return Array(repeating: .zero, count: Self.waveformSamples) }
        return (0..<Self.waveformSamples).map { index in
            let age = Double(Self.waveformSamples-1-index)/Double(Self.waveformSamples-1)*Self.waveformDuration
            let sampleTime = time-age
            guard sampleTime >= 0, sampleTime < duration else { return SIMD2<Float>.zero }
            let position = min(peaks.count-1,Int(sampleTime/peakInterval))
            // A causal 3 ms peak window preserves both polarities without
            // cancellation as the displayed snippet advances through playback.
            var value = peaks[position]
            for offset in 1...2 where position >= offset {
                value.x = min(value.x,peaks[position-offset].x)
                value.y = max(value.y,peaks[position-offset].y)
            }
            return value
        }
    }

    /// Return normalized loudness and onset accent at the specified playback time.
    public func sample(at time: Double) -> SIMD2<Float> {
        guard time.isFinite, time >= 0, time < duration, !levels.isEmpty else { return .zero }
        let position = time/interval
        let index = min(levels.count-1,Int(position))
        let next = min(levels.count-1,index+1)
        let level = levels[index]+(levels[next]-levels[index])*Float(position-Double(index))
        let previous = levels[max(0,index-4)]
        return SIMD2(level,min(1,max(0,level-previous)*2.5))
    }
}

