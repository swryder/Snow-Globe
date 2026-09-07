import Foundation

/// Appearance and motion controls shared by every Snow Globe consumer.
/// Motion and optical strength ease into new values; glass opacity responds immediately.
public struct SnowGlobeConfiguration: Equatable, Sendable {
    public enum Appearance: String, CaseIterable, Sendable { case dark, light, automatic }
    public enum Shape: String, CaseIterable, Sendable { case disc, ring }
    public enum SpeechMode: String, CaseIterable, Sendable { case live, flowing }

    /// The settings established in the sample app, including live speech with no trails.
    public static let `default` = SnowGlobeConfiguration()
    public static let particleCountRange = 10...33_600
    public static let particleSizeRange: ClosedRange<Float> = 0.5...20
    public static let idleSpeedRange: ClosedRange<Float> = 0.5...4
    public static let trailLengthRange: ClosedRange<Float> = 0...1
    public static let speechExpressionRange: ClosedRange<Float> = 0...2
    public static let flashFactorRange: ClosedRange<Float> = 0...8
    public static let glassEffectRange: ClosedRange<Float> = 0...1

    public var appearance: Appearance
    /// The container is always a sphere; this selects the internal particle distribution.
    public var shape: Shape
    /// Maximum visible population at full effort. Idle admits a smaller population.
    public var particleCount: Int
    public var particleSize: Float
    public var idleSpeed: Float
    /// Normal trail length, where 0 is off and 1 is the longest trail.
    public var trailLength: Float
    /// Used in flowing speech mode. Live waveform always forces trails to zero.
    public var speakingTrailLength: Float
    public var speechExpression: Float
    public var speechMode: SpeechMode
    /// Voice lighting gain. Values above 1 use available display EDR headroom.
    public var flashFactor: Float
    /// Clear pixels outside the sphere for overlays and borderless windows.
    public var transparentBackground: Bool
    /// Optical refraction through the curved glass. Zero restores the original image.
    public var glassEffect: Float
    /// Opacity of the glass body only, independent of optical strength.
    /// Zero makes the glass clear; particles and trails retain their own opacity.
    public var opacity: Float

    public init(appearance: Appearance = .dark, shape: Shape = .disc,
                particleCount: Int = 10_000, particleSize: Float = 1.75,
                idleSpeed: Float = 4, trailLength: Float = 0.30,
                speakingTrailLength: Float = 0.50, speechExpression: Float = 1,
                speechMode: SpeechMode = .live, flashFactor: Float = 3,
                transparentBackground: Bool = false, glassEffect: Float = 0.45, opacity: Float = 1) {
        self.appearance = appearance
        self.shape = shape
        self.particleCount = particleCount
        self.particleSize = particleSize
        self.idleSpeed = idleSpeed
        self.trailLength = trailLength
        self.speakingTrailLength = speakingTrailLength
        self.speechExpression = speechExpression
        self.speechMode = speechMode
        self.flashFactor = flashFactor
        self.transparentBackground = transparentBackground
        self.glassEffect = glassEffect
        self.opacity = opacity
    }

    /// Clamp at the API boundary without allowing NaN or infinity into the GPU simulation.
    var normalized: Self {
        var result = self
        result.particleCount = min(Self.particleCountRange.upperBound, max(Self.particleCountRange.lowerBound, particleCount))
        result.particleSize = sanitized(particleSize, in: Self.particleSizeRange, fallback: Self.default.particleSize)
        result.idleSpeed = sanitized(idleSpeed, in: Self.idleSpeedRange, fallback: Self.default.idleSpeed)
        result.trailLength = sanitized(trailLength, in: Self.trailLengthRange, fallback: Self.default.trailLength)
        result.speakingTrailLength = sanitized(speakingTrailLength, in: Self.trailLengthRange, fallback: Self.default.speakingTrailLength)
        result.speechExpression = sanitized(speechExpression, in: Self.speechExpressionRange, fallback: Self.default.speechExpression)
        result.flashFactor = sanitized(flashFactor, in: Self.flashFactorRange, fallback: Self.default.flashFactor)
        result.glassEffect = sanitized(glassEffect, in: Self.glassEffectRange, fallback: Self.default.glassEffect)
        result.opacity = sanitized(opacity, in: 0...1, fallback: 1)
        return result
    }
}

func sanitized(_ value: Float, in range: ClosedRange<Float>, fallback: Float) -> Float {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
