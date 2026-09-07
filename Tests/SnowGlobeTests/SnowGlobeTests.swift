import XCTest
import Metal
@testable import SnowGlobe

final class SnowGlobeTests: XCTestCase {
    func testShippedDefaultsAndInputBoundary() {
        let value = SnowGlobeConfiguration.default
        XCTAssertEqual(value.particleCount, 10_000)
        XCTAssertEqual(value.particleSize, 1.75)
        XCTAssertEqual(value.idleSpeed, 4)
        XCTAssertEqual(value.trailLength, 0.30)
        XCTAssertEqual(value.speakingTrailLength, 0.50)
        XCTAssertEqual(value.shape, .disc)
        XCTAssertEqual(value.speechMode, .live)
        XCTAssertEqual(value.speechExpression, 1)
        XCTAssertEqual(value.flashFactor, 3)
        XCTAssertEqual(value.appearance, .dark)
        XCTAssertFalse(value.transparentBackground)
        XCTAssertEqual(value.glassEffect,0.45)
        XCTAssertEqual(value.opacity,1)
        XCTAssertEqual(value.motionSensitivity,1)
        var invalid = value
        invalid.particleCount = Int.max
        invalid.particleSize = .nan
        invalid.idleSpeed = -.infinity
        invalid.trailLength = -1
        invalid.speakingTrailLength = 10
        invalid.flashFactor = .infinity
        invalid.speechExpression = 3
        invalid.glassEffect = .nan
        invalid.opacity = 2
        invalid.motionSensitivity = .infinity
        let safe = invalid.normalized
        XCTAssertEqual(safe.particleCount, 33_600)
        XCTAssertEqual(safe.particleSize, value.particleSize)
        XCTAssertEqual(safe.idleSpeed, value.idleSpeed)
        XCTAssertEqual(safe.trailLength, 0)
        XCTAssertEqual(safe.speakingTrailLength, 1)
        XCTAssertEqual(safe.flashFactor, value.flashFactor)
        XCTAssertEqual(safe.speechExpression, 2)
        XCTAssertEqual(safe.glassEffect,value.glassEffect)
        XCTAssertEqual(safe.opacity,1)
        XCTAssertEqual(safe.motionSensitivity,1)
        invalid.motionSensitivity = -1
        XCTAssertEqual(invalid.normalized.motionSensitivity,0)
        invalid.particleCount = Int.min
        XCTAssertEqual(invalid.normalized.particleCount, 10)
    }

    func testSpeechMailboxSessionAndUntrustedSamples() {
        let meter = SpeechMeter()
        XCTAssertFalse(meter.snapshot().sessionActive)
        meter.store(SIMD2(.nan, 2), waveform: Array(repeating: SIMD2(-2, .infinity), count: 512), sessionActive: true)
        let clipped = meter.snapshot()
        XCTAssertEqual(clipped.level, SIMD2(0, 1))
        XCTAssertTrue(clipped.waveform.allSatisfy { $0 == SIMD2(-1, 0) })
        meter.store(.zero)
        XCTAssertTrue(meter.snapshot().sessionActive, "Quiet sentence gaps must keep the session active")
        meter.store(.zero, waveform: [SIMD2(-1, 1)], sessionActive: false)
        XCTAssertFalse(meter.snapshot().sessionActive)
        XCTAssertEqual(meter.snapshot().waveform.count, 512)
        XCTAssertTrue(meter.snapshot().waveform.allSatisfy { $0 == .zero })
    }

    func testAudioEnvelopeAndNonFiniteTimes() throws {
        let envelope = try SpeechEnvelope(url: fixtureURL)
        XCTAssertEqual(envelope.sample(at: .nan), .zero)
        XCTAssertEqual(envelope.sample(at: .infinity), .zero)
        XCTAssertTrue(envelope.waveform(at: .infinity).allSatisfy { $0 == .zero })
        XCTAssertTrue(envelope.waveform(at: envelope.duration + 1).allSatisfy { $0 == .zero })
        XCTAssertGreaterThan(envelope.duration, 1)
    }

    #if os(macOS)
    func testGlassRefraction() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required for render validation") }
        let output = ProcessInfo.processInfo.environment["SNOW_GLOBE_GLASS_OUTPUT"] ??
            FileManager.default.temporaryDirectory.appendingPathComponent("SnowGlobeGlass-\(UUID().uuidString)").path
        print("Glass refraction previews: \(output)")
        try RenderValidation.checkGlass(in: URL(fileURLWithPath: output))
    }

    func testTransparentGlobeCompositing() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required for render validation") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowGlobeAlpha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try RenderValidation.checkTransparency(in: directory)
    }

    func testGlassTransparencyPreservesParticles() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required for render validation") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnowGlobeGlassOpacity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try RenderValidation.checkGlassOpacity(in: directory)
    }

    func testProductionMetalRegression() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal GPU required for render validation") }
        let directory = ProcessInfo.processInfo.environment["SNOW_GLOBE_VALIDATION_OUTPUT"] ??
            FileManager.default.temporaryDirectory.appendingPathComponent("SnowGlobeValidation-\(UUID().uuidString)").path
        print("Snow Globe render artifacts: \(directory)")
        try RenderValidation.run(directory: directory, speechAudioURL: fixtureURL)
    }
    #endif

    private var fixtureURL: URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        return bundle.url(forResource: "SpeechFixture", withExtension: "aiff", subdirectory: "Fixtures")!
    }
}
