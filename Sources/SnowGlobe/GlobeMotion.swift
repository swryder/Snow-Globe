import Foundation
import QuartzCore
import simd

/// Optional physical input for one globe. Keep this instance across view updates.
/// macOS views automatically measure their containing window's acceleration.
/// Other hosts can supply acceleration and gravity in view coordinates:
/// x right, y up, z toward the viewer. Acceleration excludes gravity and is
/// measured in globe radii per second squared; gravity is a direction.
public final class GlobeMotion: @unchecked Sendable {
    private let lock = NSLock()
    private var acceleration = SIMD3<Float>.zero
    private var gravity = SIMD3<Float>(0, -1, 0)
    private var sampleTime = -Double.infinity
    private var shakeTime = -Double.infinity
    private var shakeStrength: Float = 0

    public init() {}

    /// Feed device motion at the sensor's cadence. Stale acceleration fades out
    /// after 100 ms; the last gravity direction is retained until reset.
    public func update(acceleration: SIMD3<Float>, gravity: SIMD3<Float> = SIMD3(0, -1, 0)) {
        store(acceleration: acceleration, gravity: gravity, at: CACurrentMediaTime())
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        acceleration = .zero
        gravity = SIMD3(0, -1, 0)
        sampleTime = -.infinity
        shakeTime = -.infinity
    }

    /// A short physical shake, useful for embedded globes and tuning controls.
    public func shake(strength: Float = 1) {
        lock.lock()
        defer { lock.unlock() }
        shakeTime = CACurrentMediaTime()
        shakeStrength = sanitized(strength, in: 0...2, fallback: 1)
    }

    func store(acceleration: SIMD3<Float>, gravity: SIMD3<Float>, at time: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.acceleration = boundedMotion(acceleration, limit: 32)
        let direction = boundedMotion(gravity, limit: 1)
        self.gravity = simd_length(direction) > 0.001 ? simd_normalize(direction) : SIMD3(0, -1, 0)
        sampleTime = time.isFinite ? time : -.infinity
    }

    func snapshot(at time: Double) -> (acceleration: SIMD3<Float>, gravity: SIMD3<Float>) {
        lock.lock()
        defer { lock.unlock() }
        let age = time - sampleTime
        let freshness: Float = age >= 0 && age < 0.25 ? Float(min(1, (0.25-age)/0.15)) : 0
        var value = acceleration * freshness
        let shakeAge = time - shakeTime
        if shakeAge >= 0 && shakeAge < 0.65 {
            let phase = Float(shakeAge / 0.65)
            let envelope = sin(.pi * phase)
            value += SIMD3(20 * sin(phase * 4 * .pi), 12 * sin(phase * 2 * .pi), 0) * envelope * shakeStrength
        }
        return (boundedMotion(value, limit: 32), gravity)
    }
}

func boundedMotion(_ value: SIMD3<Float>, limit: Float) -> SIMD3<Float> {
    guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { return .zero }
    // Scale before taking a length so huge finite input cannot overflow. Preserve
    // its direction, including gravity supplied in units other than a unit vector.
    let largest = max(abs(value.x), max(abs(value.y), abs(value.z)))
    let clipped = value * min(1, limit / max(0.0001, largest))
    return clipped * min(1, limit / max(0.0001, simd_length(clipped)))
}

/// Sample at display cadence, not at the uneven cadence of mouse events.
/// Differentiating filtered velocity captures both acceleration and braking.
struct GlobeWindowMotion {
    private var previousPosition: SIMD2<Double>?
    private var previousTime: Double = 0
    private var previousRadius: Double = 0
    private var previousWindow: Int = 0
    private var velocity = SIMD2<Float>.zero
    private var acceleration = SIMD3<Float>.zero

    mutating func sample(position: SIMD2<Double>, radius: Double, window: Int, at time: Double) -> SIMD3<Float> {
        let dt = time - previousTime
        defer {
            previousPosition = position
            previousTime = time
            previousRadius = radius
            previousWindow = window
        }
        guard position.x.isFinite, position.y.isFinite, radius.isFinite, time.isFinite,
              let previousPosition, radius > 1, previousRadius > 1, window == previousWindow,
              abs(radius / previousRadius - 1) < 0.01, dt > 0.001, dt < 0.15,
              simd_length(position - previousPosition) < radius * 4 else {
            velocity = .zero
            acceleration = .zero
            return .zero
        }
        let raw = SIMD2<Float>((position - previousPosition) / radius / dt)
        let measured = simd_clamp(raw, SIMD2(repeating: -12), SIMD2(repeating: 12))
        let filtered = velocity + (measured - velocity) * Float(1 - exp(-dt * 30))
        let change = (filtered - velocity) / Float(dt)
        velocity = filtered
        let force = boundedMotion(SIMD3(-change.x, -change.y, 0), limit: 24)
        acceleration += (force - acceleration) * Float(1 - exp(-dt * 22))
        return simd_length(acceleration) < 0.04 ? .zero : acceleration
    }
}
