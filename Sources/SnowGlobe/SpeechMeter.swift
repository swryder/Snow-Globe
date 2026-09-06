import Foundation

/// A small, locked mailbox keeps audio metering out of SwiftUI's update loop.
public final class SpeechMeter: @unchecked Sendable {
    /// Creates a silent mailbox with no active speech session.
    public init() {}
    private static let silentWaveform = [SIMD2<Float>](repeating: .zero,count: SpeechEnvelope.waveformSamples)
    private let lock = NSLock()
    private var value = SIMD2<Float>.zero
    private var waveform = SpeechMeter.silentWaveform
    private var sessionActive = false
    /// Publish perceived loudness and onset accent in 0...1, plus optional signed PCM peaks.
    /// Waveform data must contain 512 (negative minimum, positive maximum) pairs,
    /// ordered oldest to newest over 480 ms. Missing/invalid arrays become silence.
    /// Omit sessionActive to retain the current state across quiet sentence gaps.
    /// Send false on completion/cancellation for a fast return to normal animation.
    public func store(_ next: SIMD2<Float>, waveform: [SIMD2<Float>] = [], sessionActive: Bool? = nil) {
        let level = SIMD2(sanitized(next.x, in: 0...1, fallback: 0), sanitized(next.y, in: 0...1, fallback: 0))
        let peaks = waveform.count == SpeechEnvelope.waveformSamples ? waveform.map {
            SIMD2(sanitized($0.x, in: -1...0, fallback: 0), sanitized($0.y, in: 0...1, fallback: 0))
        } : Self.silentWaveform
        lock.lock(); value = level
        self.waveform = peaks
        if let sessionActive { self.sessionActive = sessionActive }
        lock.unlock()
    }
    /// Read the current loudness and onset accent.
    public func sample() -> SIMD2<Float> { lock.lock(); defer { lock.unlock() }; return value }
    /// Atomically read matching level, waveform, and session state.
    public func snapshot() -> (level: SIMD2<Float>, waveform: [SIMD2<Float>], sessionActive: Bool) {
        lock.lock(); defer { lock.unlock() }; return (value,waveform,sessionActive)
    }
}

