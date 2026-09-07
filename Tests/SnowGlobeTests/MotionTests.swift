import XCTest
import Metal
import simd
@testable import SnowGlobe

final class MotionTests: XCTestCase {
    func testWindowAccelerationAndDiscontinuities() {
        var tracker = GlobeWindowMotion()
        XCTAssertEqual(tracker.sample(position: .zero, radius: 200, window: 1, at: 1), .zero)
        let start = tracker.sample(position: SIMD2(10, 0), radius: 200, window: 1, at: 1.02)
        XCTAssertLessThan(start.x, -1, "Snow lags behind a window accelerating right")
        var cruising = SIMD3<Float>.zero
        for frame in 2...80 {
            cruising = tracker.sample(position: SIMD2(Double(frame)*10, 0), radius: 200, window: 1, at: 1+Double(frame)*0.02)
        }
        XCTAssertLessThan(simd_length(cruising), 0.1, "Constant velocity should not continuously force the snow")
        let stop = tracker.sample(position: SIMD2(800, 0), radius: 200, window: 1, at: 2.62)
        XCTAssertGreaterThan(stop.x, 1, "Braking carries snow forward")
        XCTAssertEqual(tracker.sample(position: SIMD2(3000, 0), radius: 200, window: 1, at: 2.64), .zero)
        XCTAssertEqual(tracker.sample(position: SIMD2(3010, 0), radius: 200, window: 2, at: 2.66), .zero)
        XCTAssertEqual(tracker.sample(position: SIMD2(3020, 0), radius: 400, window: 2, at: 2.68), .zero)
        XCTAssertEqual(tracker.sample(position: SIMD2(3030, 0), radius: 400, window: 2, at: 5), .zero)
        XCTAssertEqual(tracker.sample(position: SIMD2(.nan, 0), radius: 400, window: 2, at: 5.02), .zero)
        XCTAssertEqual(tracker.sample(position: SIMD2(3040, 0), radius: 400, window: 2, at: 5.04), .zero)
    }

    func testPhysicalInputSanitizingAndExpiry() {
        let input = GlobeMotion()
        input.store(acceleration: SIMD3(100, 0, 0), gravity: SIMD3(0, -9.8, 0), at: 1)
        XCTAssertEqual(input.snapshot(at: 1.05).acceleration, SIMD3(32, 0, 0))
        XCTAssertLessThan(input.snapshot(at: 1.2).acceleration.x, 12)
        XCTAssertEqual(input.snapshot(at: 1.3).acceleration, .zero)
        XCTAssertEqual(input.snapshot(at: 0).acceleration, .zero)
        input.store(acceleration: SIMD3(.nan, .infinity, 0), gravity: .zero, at: 2)
        XCTAssertEqual(input.snapshot(at: 2).acceleration, .zero)
        XCTAssertEqual(input.snapshot(at: 2).gravity, SIMD3(0, -1, 0))
        input.store(acceleration: SIMD3(1, 2, 3), gravity: SIMD3(1, 0, 0), at: 3)
        input.reset()
        XCTAssertEqual(input.snapshot(at: 3).acceleration, .zero)
        XCTAssertEqual(input.snapshot(at: 3).gravity, SIMD3(0, -1, 0))
    }

    func testMetalInertiaWakeContainmentAndResettling() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        let renderer = try ParticleRenderer()
        renderer.targetConnected = false
        var time = 0.0
        try advance(renderer, seconds: 10, time: &time)
        let before = state(renderer)
        XCTAssertGreaterThan(sleeping(before), 0.95)
        let input = GlobeMotion()
        renderer.motionInput = input
        try advance(renderer, seconds: 0.2, time: &time) { _ in SIMD3(-12, 8, 0) }
        let shaken = state(renderer)
        let lag = centroid(shaken).x - centroid(before).x
        let rise = centroid(shaken).y - centroid(before).y
        print("Inertia initial response: lag=\(lag), rise=\(rise), sleeping=\(sleeping(shaken))")
        XCTAssertLessThan(lag, -0.08)
        XCTAssertGreaterThan(rise, 0.03)
        XCTAssertLessThan(sleeping(shaken), 0.05)
        try advance(renderer, seconds: 1.2, time: &time) { elapsed in
            SIMD3(28 * sin(Float(elapsed)*18), 20 * cos(Float(elapsed)*13), 8 * sin(Float(elapsed)*9))
        }
        try advance(renderer, seconds: 18, time: &time)
        let settled = state(renderer)
        print("Inertia resettled: sleeping=\(sleeping(settled)), center=\(centroid(settled))")
        XCTAssertGreaterThan(sleeping(settled), 0.95)
        XCTAssertLessThan(centroid(settled).y, -0.74)
        for (a,b) in zip(before,settled) { XCTAssertEqual(a.position.w,b.position.w, "Shaking must preserve particle admission") }
        let frozen = settled.map(\.position)
        try advance(renderer, seconds: 0.5, time: &time)
        let after = state(renderer)
        for id in after.indices where settled[id].appearance.w < -50 {
            XCTAssertEqual(after[id].position, frozen[id], "Sleeping snow must not jitter")
        }

        // The shared input is ready for a future device-motion adapter.
        let down = simd_normalize(SIMD3<Float>(-0.65,-1,0))
        try advance(renderer, seconds: 16, time: &time, gravity: down)
        let tilted = state(renderer)
        print("Tilted bed: sleeping=\(sleeping(tilted)), center=\(centroid(tilted))")
        XCTAssertLessThan(centroid(tilted).x, -0.25)
        XCTAssertGreaterThan(sleeping(tilted), 0.9)
        try advance(renderer, seconds: 1, time: &time, gravity: -down)
        XCTAssertGreaterThan(simd_dot(renderer.gravityDirection, -down), 0.99,
                             "Turning a device upside down must not stall gravity interpolation")
    }

    func testConnectedInfluenceAndDisabledMotion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required") }
        let active = try ParticleRenderer()
        let control = try ParticleRenderer()
        active.motionInput = GlobeMotion()
        var timeA = 0.0, timeB = 0.0
        try advance(active, seconds: 0.2, time: &timeA) { _ in SIMD3(-12, 8, 0) }
        try advance(control, seconds: 0.2, time: &timeB)
        let delta = simd_length(centroid(state(active))-centroid(state(control)))
        print("AI connected physical displacement: \(delta)")
        XCTAssertGreaterThan(delta, 0.004)
        XCTAssertLessThan(delta, 0.09, "Currents should substantially resist physical disturbance")

        active.targetActivity = 1
        active.targetLiveWaveform = 1
        active.targetSpeechSessionActive = true
        active.targetSpeech = SIMD2(0.6,0.4)
        active.targetSpeechWaveform = (0..<SpeechEnvelope.waveformSamples).map {
            SIMD2(0.4 * sin(Float($0)*0.1),0.3 * cos(Float($0)*0.12))
        }
        try advance(active, seconds: 3, time: &timeA) { elapsed in
            SIMD3(20 * sin(Float(elapsed)*12),16 * cos(Float(elapsed)*10),0)
        }
        XCTAssertGreaterThan(active.speechPresence,0.9)
        XCTAssertLessThan(active.effectiveTrailLength,0.001,
                          "Physical motion must preserve live speech and its trail suppression")

        let disabled = try ParticleRenderer()
        let baseline = try ParticleRenderer()
        disabled.motionInput = GlobeMotion()
        disabled.motionSensitivity = 0
        disabled.targetConnected = false
        baseline.targetConnected = false
        timeA = 0; timeB = 0
        try advance(disabled, seconds: 2, time: &timeA) { _ in SIMD3(32, 24, 0) }
        try advance(baseline, seconds: 2, time: &timeB)
        for (a,b) in zip(state(disabled),state(baseline)) {
            XCTAssertEqual(a.position,b.position)
            XCTAssertEqual(a.velocity,b.velocity)
        }
    }

    private func advance(_ renderer: ParticleRenderer, seconds: Double, time: inout Double,
                         gravity: SIMD3<Float> = SIMD3(0,-1,0),
                         force: (Double) -> SIMD3<Float> = { _ in .zero }) throws {
        let start = time
        let steps = Int((seconds / Double(ParticleRenderer.fixedStep)).rounded())
        var remaining = steps
        while remaining > 0 {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let count = min(12,remaining)
            for _ in 0..<count {
                renderer.motionInput?.store(acceleration: force(time-start), gravity: gravity, at: time)
                renderer.sampleMotion(at: time)
                renderer.step(command: command)
                time += Double(ParticleRenderer.fixedStep)
            }
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
            XCTAssertTrue(state(renderer).allSatisfy { particle in
                let p = SIMD3(particle.position.x,particle.position.y,particle.position.z)
                return p.x.isFinite && p.y.isFinite && p.z.isFinite && simd_length(p) <= 0.9401
            }, "Every particle must remain finite and inside the glass")
            remaining -= count
        }
    }

    private func state(_ renderer: ParticleRenderer) -> [Particle] {
        Array(UnsafeBufferPointer(start: renderer.particles.contents().assumingMemoryBound(to: Particle.self), count: ParticleRenderer.particleCount))
    }
    private func sleeping(_ particles: [Particle]) -> Float {
        Float(particles.filter { $0.appearance.w < -50 }.count)/Float(particles.count)
    }
    private func centroid(_ particles: [Particle]) -> SIMD3<Float> {
        let visible = particles.filter { $0.position.w > 0.5 }
        return visible.reduce(.zero) { $0 + SIMD3($1.position.x,$1.position.y,$1.position.z) } / Float(visible.count)
    }
}
