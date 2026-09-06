import Metal

/// Resolve resources from the package, never the host application's main bundle.
enum SnowGlobeMetalLibrary {
    static func load(device: MTLDevice) throws -> MTLLibrary {
        // Xcode compiles processed .metal resources into the package's default.metallib.
        if Bundle.module.url(forResource: "default", withExtension: "metallib") != nil {
            return try device.makeDefaultLibrary(bundle: .module)
        }
        // Command-line SwiftPM copies Metal source instead of invoking the Metal
        // build rule. Compile that same source so swift test exercises real kernels.
        guard let url = Bundle.module.url(forResource: "Particles", withExtension: "metal") else {
            throw RendererFailure.unavailable("SnowGlobe shader resources are missing from the package bundle.")
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
    }
}
