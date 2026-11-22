import XCTest
import Metal
@testable import SnowGlobe

/// The shader's hash() gives every particle its random choices (orbit, layer,
/// sparkle, fragment picks). It must stay evenly spread on every Mac, compiler
/// and GPU driver. On an M1 Max with macOS 27.2.1 the original one-line hash,
/// whose fast sin() received arguments of several million, returned only 65
/// distinct values in 1,000 bins and the idle cloud collapsed into a band.
///
/// A failure here means the argument reduction in hash() or the sin() under it
/// has changed: for example the fma() calls were split into a separate multiply
/// and subtract, or a new compiler or driver handles them differently.
final class HashQualityTests: XCTestCase {
    func testHashStaysEvenlySpreadOnTheGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal GPU required for the hash check") }
        let library = try SnowGlobeMetalLibrary.load(device: device)
        let function = try XCTUnwrap(library.makeFunction(name: "hashProbe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let count = 33_600   // the renderer's particle count
        let buffer = try XCTUnwrap(device.makeBuffer(length: count * 4, options: .storageModeShared))

        func hashes(scale: Float, offset: Float) throws -> [Float] {
            var mapping = SIMD2<Float>(scale, offset)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.setBytes(&mapping, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
            let values = buffer.contents().bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: values, count: count))
        }

        // Inputs the shader really uses: particle ids plus fixed offsets, the
        // fragment pick float(id)*0.618+event, small non-integer seeds such as
        // seed*271+113, and the integer cells of drift(). Those are
        // floor(time*rate + constant), so they grow with running time: at the
        // fastest rate, 14 per second, they reach 140,000 (the top of the
        // range tested here) after about 2.8 hours.
        let cases: [(name: String, scale: Float, offset: Float)] = [
            ("orbit phase, id+1", 1, 1),
            ("orbit lane, id+23", 1, 23),
            ("settled layer, id+4027", 1, 4027),
            ("fragment twinkle offset, id+6113", 1, 6113),
            ("fragment pick, id*0.618+event", 0.618, 140.37),
            ("fragment release, id+5813+event", 1, 5813 + 140.37),
            ("seed-style input, seed*271+113", 271.0 / 33_600, 113),
            ("drift cells from 0", 1, 0),
            ("drift cells near 140,000", 1, 106_400),
        ]
        for test in cases {
            let values = try hashes(scale: test.scale, offset: test.offset)
            XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 < 1 }, "\(test.name): value outside [0, 1)")
            let distinct = Set(values.map { Int($0 * 1000) }).count
            var bins = [Int](repeating: 0, count: 10)
            for value in values { bins[min(9, max(0, Int(value * 10)))] += 1 }
            let expected = Double(count) / 10
            let chiSquare = bins.reduce(0.0) { $0 + pow(Double($1) - expected, 2) / expected }
            // 33,600 values in 1,000 bins of 0.001: an even spread fills them all.
            XCTAssertGreaterThanOrEqual(distinct, 990, "\(test.name): only \(distinct) distinct values in 1,000")
            // Chi-square over 10 equal bins has 9 degrees of freedom: an even
            // random spread averages 9 and exceeds 30 about once in 2,500. The
            // healthy hash measures 3 to 8; the clumped one measured 10,000+.
            XCTAssertLessThan(chiSquare, 30, "\(test.name): chi-square \(chiSquare), bins \(bins)")
        }
    }
}
