#if os(macOS)
import AppKit
#else
import UIKit
#endif
import MetalKit
import CoreVideo
import simd

struct Particle {
    var position: SIMD4<Float>
    var velocity: SIMD4<Float>
    var orbit: SIMD4<Float>
    var appearance: SIMD4<Float>
}

struct Uniforms {
    var timing: SIMD4<Float>
    var viewport: SIMD4<Float>
    var counts: SIMD4<UInt32>
    var motion: SIMD4<Float>
    var controls: SIMD4<Float>
    var orientation: SIMD4<Float>
    var response: SIMD4<Float>
    var speech: SIMD4<Float>
    var speechLight: SIMD4<Float>
    var speechMode: SIMD4<Float>
    var connection: SIMD4<Float>
    var optics: SIMD4<Float>
    var backdropUV: SIMD4<Float>
    var inertia: SIMD4<Float>
    var gravity: SIMD4<Float>
}

enum RendererFailure: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let detail): return detail }
    }
}

/// Metal owns all particle motion and collision work. The host sends only time,
/// activity, appearance, drawable dimensions, and the display's EDR headroom.
final class ParticleRenderer: NSObject, MTKViewDelegate {
    static let particleCount = 33_600
    static let baseParticleCount: Float = 16_800
    static let minimumDensity: Float = 10 / baseParticleCount
    static let defaultParticleLimit = Float(SnowGlobeConfiguration.default.particleCount)
    static let defaultDensity = defaultParticleLimit / baseParticleCount
    static let defaultSize = SnowGlobeConfiguration.default.particleSize
    static let defaultIdleSpeed = SnowGlobeConfiguration.default.idleSpeed
    static let defaultTrailLength = SnowGlobeConfiguration.default.trailLength
    static let defaultSpeakingTrailLength = SnowGlobeConfiguration.default.speakingTrailLength
    static let defaultDisc: Float = SnowGlobeConfiguration.default.shape == .disc ? 1 : 0
    static let maximumIdleSpeed = SnowGlobeConfiguration.idleSpeedRange.upperBound
    static let gridSide = 32
    static let cellCapacity = 32
    static let fixedStep: Float = 1 / 120
    static let historySamples = 256
    static let trailSegments = 24

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let initializePipeline: MTLComputePipelineState
    private let integratePipeline: MTLComputePipelineState
    private let gridPipeline: MTLComputePipelineState
    private let collisionPipeline: MTLComputePipelineState
    private let contextMotionPipeline: MTLComputePipelineState
    private let contextPipeline: MTLRenderPipelineState
    private let contextTrailPipeline: MTLRenderPipelineState
    private let globePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState
    private let lensPipeline: MTLRenderPipelineState
    private var sceneTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    let history: MTLBuffer
    private(set) var historyCursor: UInt32 = 0
    private(set) var particles: MTLBuffer
    private var scratch: MTLBuffer
    private let gridCounts: MTLBuffer
    private let gridIndices: MTLBuffer
    /// Per-particle fragment state; see integrateParticles.
    let fragmentState: MTLBuffer
    let contextBodies: MTLBuffer
    private let contextHistory: MTLBuffer
    private let recruitCounts: MTLBuffer
    private let inFlight = DispatchSemaphore(value: 3)

    var speechMeter: SpeechMeter?
    private(set) var contexts = ContextParticles()
    private var contextSlots = [ContextSlot](repeating: ContextSlot(orbit: .zero, merge: .zero, look: .zero),
                                             count: ContextParticles.slotCount)
    /// The host's attached files. Reconciled against the previous list on every set.
    var targetContextItems: [SnowGlobeContextItem] = [] {
        didSet { if targetContextItems != oldValue { contexts.reconcile(targetContextItems, now: simulationTime) } }
    }
    var glassBackdrop: GlassBackdrop?
    var motionInput: GlobeMotion? {
        didSet {
            if motionInput !== oldValue {
                windowMotion = GlobeWindowMotion()
                motionTarget = .zero
                physicalAcceleration = .zero
                gravityDirection = SIMD3(0, -1, 0)
                gravityTarget = gravityDirection
                agitation = 0
            }
        }
    }
    var motionSensitivity: Float = 1
    private var windowMotion = GlobeWindowMotion()
    private var motionTarget = SIMD3<Float>.zero
    private var gravityTarget = SIMD3<Float>(0, -1, 0)
    private(set) var physicalAcceleration = SIMD3<Float>.zero
    private(set) var gravityDirection = SIMD3<Float>(0, -1, 0)
    private(set) var agitation: Float = 0

    func sampleMotion(at time: Double, windowAcceleration: SIMD3<Float> = .zero) {
        let sample = motionInput?.snapshot(at: time)
        let gain = sanitized(motionSensitivity, in: 0...2, fallback: 1)
        motionTarget = sample == nil ? .zero : boundedMotion((sample!.acceleration + windowAcceleration) * gain, limit: 40)
        gravityTarget = gain > 0 ? (sample?.gravity ?? SIMD3(0, -1, 0)) : SIMD3(0, -1, 0)
    }

    var targetGlassEffect: Float = 0
    private(set) var glassEffect: Float = 0
    var opacity: Float = 1
    var targetConnected = true
    var transparentBackground = false
    private(set) var connection: Float = 1
    var targetSpeech: SIMD2<Float> = .zero
    var targetSpeechWaveform: [SIMD2<Float>] = []
    // Nil keeps envelope-only/offscreen sources supported. Playback supplies
    // an explicit session boundary so sentence pauses do not end the animation.
    var targetSpeechSessionActive: Bool?
    private var previousSpeechSessionActive: Bool?
    static let defaultFlashFactor = SnowGlobeConfiguration.default.flashFactor
    static let maximumFlashFactor = SnowGlobeConfiguration.flashFactorRange.upperBound
    var targetFlashFactor: Float = ParticleRenderer.defaultFlashFactor
    private(set) var flashFactor: Float = ParticleRenderer.defaultFlashFactor
    var targetSpeechExpression: Float = 1
    var targetLiveWaveform: Float = 0
    private(set) var liveWaveform: Float = 0
    private(set) var speechLevel: Float = 0
    private(set) var speechAccent: Float = 0
    private(set) var speechFlashLevel: Float = 0
    private(set) var speechFlashAccent: Float = 0
    private var speechExpression: Float = 1
    private var speechTime: Float = 0
    static let speechHistorySamples = 480
    private(set) var speechHistory = [SIMD2<Float>](repeating: .zero, count: speechHistorySamples)
    private(set) var speechHistoryCursor = 0
    private(set) var speechPresence: Float = 0
    var targetSpeakingTrailLength: Float = ParticleRenderer.defaultSpeakingTrailLength
    private(set) var speakingTrailLength: Float = ParticleRenderer.defaultSpeakingTrailLength
    var effectiveTrailLength: Float {
        let expression = min(1,max(0,speechExpression/0.10))
        let speaking = speechPresence*expression*expression*(3-2*expression)
        return (trailLength+(speakingTrailLength*(1-liveWaveform)-trailLength)*speaking)*connection
    }
    var targetActivity: Float = 0
    var targetDark: Float = 1
    var targetDisc: Float = ParticleRenderer.defaultDisc
    var targetDensity: Float = ParticleRenderer.defaultDensity
    var targetSize: Float = ParticleRenderer.defaultSize
    var targetIdleSpeed: Float = ParticleRenderer.defaultIdleSpeed
    var targetTrailLength: Float = ParticleRenderer.defaultTrailLength
    private(set) var activity: Float = 0
    private(set) var dark: Float = 1
    private(set) var disc: Float = ParticleRenderer.defaultDisc
    private(set) var density: Float = ParticleRenderer.defaultDensity
    private(set) var particleSize: Float = ParticleRenderer.defaultSize
    private(set) var idleSpeed: Float = ParticleRenderer.defaultIdleSpeed
    private(set) var trailLength: Float = ParticleRenderer.defaultTrailLength
    // Full discs through 40%; release their inward guidance progressively as
    // energy climbs. Smooth endpoints avoid a kink when crossing the threshold.
    var effectiveDisc: Float {
        let x = min(1, max(0, (activity - 0.40) / 0.60))
        let release = x * x * x * (x * (x * 6 - 15) + 10)
        return disc * min(1, max(0, 1 - release))
    }
    var sparkleLevel: Float {
        let x = min(1, max(0, (activity-0.15)/0.65))
        // A soft onset becomes perceptible soon after 15%, with a smooth
        // shoulder into full sparkle at 80%.
        return pow(x*x*(3-2*x),0.65)
    }
    private(set) var simulationTime: Float = 0
    private(set) var flowTime: Float = 0
    private(set) var effortResponseBoost: Float = 0
    private(set) var ringOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0,1,0))
    var motionRate: Float {
        let eased = activity * activity * (3 - 2 * activity)
        // A broad, smooth lift centered on 50%: 20% more movement there,
        // tapering to the existing pace at idle and maximum effort.
        let midpoint = 16 * activity * activity * (1-activity) * (1-activity)
        let floor = 0.20 * idleSpeed
        return (floor + (1-floor) * eased) * (1 + 0.20 * midpoint)
    }
    private var lastTime: CFTimeInterval = 0
    private var accumulator: Double = 0
    private var headroom: Float = 1

    init(initialDark: Float = 1, initialDisc: Float = ParticleRenderer.defaultDisc,
         initialIdleSpeed: Float = ParticleRenderer.defaultIdleSpeed,
         initialDensity: Float = ParticleRenderer.defaultDensity,
         initialSize: Float = ParticleRenderer.defaultSize,
         initialTrailLength: Float = ParticleRenderer.defaultTrailLength) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw RendererFailure.unavailable("Snow Globe requires a Metal-capable GPU.")
        }
        self.device = device
        self.queue = queue
        let library = try SnowGlobeMetalLibrary.load(device: device)
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RendererFailure.unavailable("Missing Metal function: \(name)")
            }
            return try device.makeComputePipelineState(function: function)
        }
        initializePipeline = try compute("initializeParticles")
        integratePipeline = try compute("integrateParticles")
        gridPipeline = try compute("buildGrid")
        collisionPipeline = try compute("collideParticles")
        contextMotionPipeline = try compute("advanceContextItems")

        func render(vertex: String, fragment: String, blend: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .rgba16Float
            attachment.isBlendingEnabled = blend
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        globePipeline = try render(vertex: "fullscreenVertex", fragment: "globeFragment", blend: false)
        particlePipeline = try render(vertex: "particleVertex", fragment: "particleFragment", blend: true)
        trailPipeline = try render(vertex: "trailVertex", fragment: "trailFragment", blend: true)
        lensPipeline = try render(vertex: "fullscreenVertex", fragment: "glassLensFragment", blend: false)
        contextPipeline = try render(vertex: "contextVertex", fragment: "contextFragment", blend: true)
        contextTrailPipeline = try render(vertex: "contextTrailVertex", fragment: "trailFragment", blend: true)

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw RendererFailure.unavailable("Could not allocate \(label).")
            }
            buffer.label = label
            return buffer
        }
        history = try buffer(Self.historySamples * Self.particleCount * MemoryLayout<SIMD4<Float>>.stride, "Particle path history")
        particles = try buffer(Self.particleCount * MemoryLayout<Particle>.stride, "Particles")
        scratch = try buffer(Self.particleCount * MemoryLayout<Particle>.stride, "Integrated particles")
        let cells = Self.gridSide * Self.gridSide * Self.gridSide
        gridCounts = try buffer(cells * 4, "Collision cell counts")
        gridIndices = try buffer(cells * Self.cellCapacity * 4, "Collision cell indices")
        fragmentState = try buffer(Self.particleCount * MemoryLayout<SIMD4<Float>>.stride, "Context fragment state")
        contextBodies = try buffer(ContextParticles.slotCount * MemoryLayout<ContextBody>.stride, "Context particles")
        contextHistory = try buffer(Self.historySamples * ContextParticles.slotCount * MemoryLayout<SIMD4<Float>>.stride, "Context particle path history")
        recruitCounts = try buffer(ContextParticles.slotCount * 4, "Context fragment recruit counts")
        super.init()
        CVMetalTextureCacheCreate(nil,nil,device,nil,&textureCache)
        dark = initialDark
        targetDark = initialDark
        disc = initialDisc
        targetDisc = initialDisc
        idleSpeed = min(Self.maximumIdleSpeed, max(0.5, initialIdleSpeed))
        targetIdleSpeed = idleSpeed
        density = min(2, max(Self.minimumDensity, initialDensity))
        targetDensity = density
        particleSize = min(20, max(0.5, initialSize))
        targetSize = particleSize
        trailLength = min(1, max(0, initialTrailLength))
        targetTrailLength = trailLength
        try reset()
    }

    func uniforms(size: CGSize, scale: Float = 2, edr: Float = 1, clockRate: Float? = nil) -> Uniforms {
        Uniforms(timing: SIMD4(simulationTime, Self.fixedStep, activity, dark),
                 viewport: SIMD4(Float(size.width), Float(size.height), scale, edr),
                 counts: SIMD4(UInt32(Self.particleCount), UInt32(Self.gridSide), UInt32(Self.cellCapacity), historyCursor),
                 motion: SIMD4(flowTime, clockRate ?? motionRate, 0.40 + 0.60 * activity, effectiveDisc),
                 controls: SIMD4(density, particleSize, effectiveTrailLength, sparkleLevel),
                 orientation: ringOrientation.vector,
                 response: SIMD4(effortResponseBoost, Float(speechHistoryCursor), speechExpression, 3.2),
                 speech: SIMD4(speechLevel*speechExpression, speechAccent*speechExpression, speechTime, speechPresence*min(1,speechExpression)),
                 speechLight: SIMD4(flashFactor, speechFlashLevel*speechExpression, speechFlashAccent*speechExpression, speechPresence),
                 speechMode: SIMD4(liveWaveform, Float(SpeechEnvelope.waveformDuration), targetSpeechWaveform.count == SpeechEnvelope.waveformSamples ? 1 : 0, Float(SpeechEnvelope.waveformSamples)),
                 connection: SIMD4(connection,targetConnected ? 1 : 0,transparentBackground ? 1 : 0,0),
                 optics: SIMD4(glassEffect,opacity,0,0),
                 backdropUV: SIMD4(0,0,1,1),
                 inertia: SIMD4(physicalAcceleration, agitation),
                 gravity: SIMD4(gravityDirection, motionInput != nil && motionSensitivity > 0 ? 1 : 0))
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState) {
        encoder.setComputePipelineState(pipeline)
        encoder.dispatchThreads(MTLSize(width: Self.particleCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    }

    func reset() throws {
        activity = 0
        simulationTime = 0
        flowTime = 0
        effortResponseBoost = 0
        speechLevel = 0; speechAccent = 0; speechTime = 0
        speechFlashLevel = 0; speechFlashAccent = 0
        targetSpeechWaveform = []
        speechHistory = [SIMD2<Float>](repeating: .zero, count: Self.speechHistorySamples)
        speechHistoryCursor = 0; speechPresence = 0
        previousSpeechSessionActive = nil
        ringOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0,1,0))
        historyCursor = 0
        accumulator = 0
        memset(fragmentState.contents(), 0, fragmentState.length)
        memset(contextBodies.contents(), 0, contextBodies.length)
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw RendererFailure.unavailable("Could not initialize the particle simulation.")
        }
        var u = uniforms(size: CGSize(width: 960, height: 960))
        encoder.setBuffer(particles, offset: 0, index: 0)
        encoder.setBuffer(history, offset: 0, index: 2)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        dispatch(encoder, initializePipeline)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        // Establish the broad suspended cloud before the first visible frame.
        // Warm only the flow, at zero energy: white, quiet, and one current.
        // End the prewarm on the real idle clock so the first visible trails
        // already have the correct gentle length and fully valid history.
        for batch in 0..<(75+Self.historySamples/8) {
            guard let warmup = queue.makeCommandBuffer() else {
                throw RendererFailure.unavailable("Could not prepare the idle cloud.")
            }
            for _ in 0..<8 { step(command: warmup, clockRate: batch < 75 ? 1 : nil) }
            warmup.commit()
            warmup.waitUntilCompleted()
            if let error = warmup.error { throw error }
        }
    }

    /// A fixed timestep makes settling and collision impulses independent of
    /// whether a display runs at 60 Hz, 120 Hz, or changes refresh rate.
    func step(command: MTLCommandBuffer, clockRate: Float? = nil) {
        let dt = Self.fixedStep
        if motionInput != nil && motionSensitivity > 0 {
            physicalAcceleration += (motionTarget - physicalAcceleration) * (1-exp(-dt*30))
            let rotation = simd_quatf(from: gravityDirection, to: gravityTarget)
            gravityDirection = simd_slerp(simd_quatf(angle: 0, axis: SIMD3(1,0,0)),
                                          rotation, 1-exp(-dt*12)).act(gravityDirection)
            agitation = max(agitation * exp(-dt*1.8), min(1, simd_length(physicalAcceleration)/7))
        } else {
            physicalAcceleration = .zero
            gravityDirection = SIMD3(0, -1, 0)
            agitation = 0
        }
        glassEffect += (min(1,max(0,targetGlassEffect))-glassEffect)*(1-exp(-dt*8))
        connection += ((targetConnected ? Float(1) : 0)-connection)*(1-exp(-dt*2.5))
        let voice = targetConnected ? simd_clamp(targetSpeech, SIMD2<Float>.zero, SIMD2<Float>(repeating: 1)) : .zero
        speechLevel += (voice.x-speechLevel)*(1-exp(-dt*(voice.x > speechLevel ? 30 : 7)))
        speechAccent += (voice.y-speechAccent)*(1-exp(-dt*(voice.y > speechAccent ? 40 : 10)))
        // A rounded pulse rises over ~30 ms and releases 90% in ~130 ms.
        // It follows syllables without the sharp blink of the earlier envelope.
        let flashLevel = pow(voice.x,1.7)
        speechFlashLevel += (flashLevel-speechFlashLevel)*(1-exp(-dt*(flashLevel > speechFlashLevel ? 32 : 18)))
        speechFlashAccent += (voice.y-speechFlashAccent)*(1-exp(-dt*(voice.y > speechFlashAccent ? 40 : 20)))
        speechExpression += (min(2,max(0,targetSpeechExpression))-speechExpression)*(1-exp(-dt*5))
        liveWaveform += (min(1,max(0,targetLiveWaveform))-liveWaveform)*(1-exp(-dt*5))
        flashFactor += (min(Self.maximumFlashFactor,max(0,targetFlashFactor))-flashFactor)*(1-exp(-dt*5))
        speechTime += dt
        speechHistoryCursor = (speechHistoryCursor+1)%Self.speechHistorySamples
        speechHistory[speechHistoryCursor] = voice
        let finished = !targetConnected || targetSpeechSessionActive == false
        if finished && previousSpeechSessionActive != false {
            speechHistory = [SIMD2<Float>](repeating: .zero,count: Self.speechHistorySamples)
        }
        previousSpeechSessionActive = finished ? false : targetSpeechSessionActive
        // Keep phrase history during pauses, but bypass that hold when the
        // speech engine finishes or Stop is pressed. Release 90% in ~190 ms.
        let recent = speechHistory.reduce(Float(0)) { $0+$1.x }/Float(Self.speechHistorySamples)
        let presence: Float = finished ? 0 : min(1,max(0,(max(recent,voice.x)-0.015)/0.10))
        let release: Float = finished ? 12 : 2
        speechPresence += (presence-speechPresence)*(1-exp(-dt*(presence > speechPresence ? 4 : release)))
        let effortGap = (targetConnected ? min(1,max(0,targetActivity)) : 0) - activity
        // Small changes retain the gentle response. A larger distance from the
        // requested effort adds a temporary boost, with a soft onset and a
        // longer release so medium/large moves do not stall near their target.
        let jump = min(1, max(0, (abs(effortGap)-0.08)/0.37))
        let desiredBoost = jump*jump*(3-2*jump)
        let boostResponse: Float = desiredBoost > effortResponseBoost ? 20 : 0.8
        effortResponseBoost += (desiredBoost-effortResponseBoost) * (1-exp(-dt*boostResponse))
        let response: Float = (effortGap > 0 ? 1.65 : 1.12) + 6*effortResponseBoost
        activity += effortGap * (1 - exp(-dt * response))
        dark += (targetDark - dark) * (1 - exp(-dt * 6))
        disc += (targetDisc - disc) * (1 - exp(-dt * 2.1))
        density += (min(2, max(Self.minimumDensity, targetDensity)) - density) * (1 - exp(-dt * 3))
        particleSize += (min(20, max(0.5, targetSize)) - particleSize) * (1 - exp(-dt * 4))
        idleSpeed += (min(Self.maximumIdleSpeed, max(0.5, targetIdleSpeed)) - idleSpeed) * (1 - exp(-dt * 3))
        trailLength += (min(1, max(0, targetTrailLength)) - trailLength) * (1 - exp(-dt * 4))
        speakingTrailLength += (min(1,max(0,targetSpeakingTrailLength))-speakingTrailLength)*(1-exp(-dt*4))
        // Integrate orientation instead of multiplying elapsed time by effort:
        // changing the slider changes angular speed without jumping the planes.
        let spin = min(1, max(0, (activity-0.15)/0.75))
        let strength = spin*spin*(3-2*spin)
        let t = simulationTime
        let angularVelocity = SIMD3<Float>(0.64+0.16*sin(t*0.13),
                                           0.24*sin(t*0.11),
                                           0.85+0.14*sin(t*0.17)) * (0.14*strength)
        let angularSpeed = length(angularVelocity)
        if angularSpeed > 0.000001 {
            let turn = simd_quatf(angle: angularSpeed*dt, axis: angularVelocity/angularSpeed)
            ringOrientation = (turn*ringOrientation).normalized
        }
        // As activity subsides, settle back into the familiar edge-on idle cloud.
        let rest = min(1, max(0, (0.15-activity)/0.12))
        if rest > 0 {
            ringOrientation = simd_slerp(ringOrientation,
                simd_quatf(angle: 0, axis: SIMD3<Float>(0,1,0)), 1-exp(-dt*0.8*rest)).normalized
        }
        historyCursor = (historyCursor + 1) % UInt32(Self.historySamples)
        simulationTime += dt
        flowTime += dt * (clockRate ?? motionRate)
        var u = uniforms(size: CGSize(width: 960, height: 960), clockRate: clockRate)
        let stepSlots = advanceContexts(command: command, uniforms: &u)
        guard let integrate = command.makeComputeCommandEncoder() else { return }
        integrate.label = "Advect in organic currents"
        integrate.setBuffer(particles, offset: 0, index: 0)
        integrate.setBuffer(scratch, offset: 0, index: 1)
        integrate.setBuffer(history, offset: 0, index: 3)
        integrate.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 2)
        speechHistory.withUnsafeBytes { integrate.setBytes($0.baseAddress!, length: $0.count, index: 4) }
        let waveform = targetSpeechWaveform.count == SpeechEnvelope.waveformSamples ? targetSpeechWaveform : [SIMD2<Float>](repeating: .zero,count: SpeechEnvelope.waveformSamples)
        waveform.withUnsafeBytes { integrate.setBytes($0.baseAddress!, length: $0.count, index: 5) }
        integrate.setBuffer(fragmentState, offset: 0, index: 6)
        integrate.setBuffer(contextBodies, offset: 0, index: 7)
        let slots = stepSlots
        slots.withUnsafeBytes { integrate.setBytes($0.baseAddress!, length: $0.count, index: 8) }
        integrate.setBuffer(recruitCounts, offset: 0, index: 9)
        dispatch(integrate, integratePipeline)
        integrate.endEncoding()

        if activity > 0.79 && targetConnected {
            if let clear = command.makeBlitCommandEncoder() {
                clear.fill(buffer: gridCounts, range: 0..<gridCounts.length, value: 0)
                clear.endEncoding()
            }
            if let grid = command.makeComputeCommandEncoder() {
                grid.label = "Build collision neighborhood grid"
                grid.setBuffer(scratch, offset: 0, index: 0)
                grid.setBuffer(gridCounts, offset: 0, index: 1)
                grid.setBuffer(gridIndices, offset: 0, index: 2)
                grid.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 3)
                dispatch(grid, gridPipeline)
                grid.endEncoding()
            }
            if let collision = command.makeComputeCommandEncoder() {
                collision.label = "Resolve crossing-current collisions"
                collision.setBuffer(scratch, offset: 0, index: 0)
                collision.setBuffer(particles, offset: 0, index: 1)
                collision.setBuffer(gridCounts, offset: 0, index: 2)
                collision.setBuffer(gridIndices, offset: 0, index: 3)
                collision.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 4)
                dispatch(collision, collisionPipeline)
                collision.endEncoding()
            }
        } else {
            swap(&particles, &scratch)
        }
    }

    /// Move the large context particles and prepare this step's slots. Returns
    /// the slots for integration, with recruit gates set only on a breakup's first step.
    private func advanceContexts(command: MTLCommandBuffer, uniforms u: inout Uniforms) -> [ContextSlot] {
        contexts.advance(dt: Self.fixedStep, now: simulationTime, flowFullness: u.motion.z, rate: u.motion.y)
        let admitted = min(Float(Self.particleCount), max(10, density*Self.baseParticleCount))
        let fullness = min(1, max(0, (activity-0.02)/0.68))
        let mainStream = admitted*7200/16800*(0.33+0.67*fullness*fullness*(3-2*fullness))
        let (slots, recruiting) = contexts.takeSlots(now: simulationTime, visibleStream: mainStream)
        contextSlots = slots
        if !recruiting.isEmpty, let clear = command.makeBlitCommandEncoder() {
            for slot in recruiting { clear.fill(buffer: recruitCounts, range: slot*4..<slot*4+4, value: 0) }
            clear.endEncoding()
        }
        if contexts.isVisible, let motion = command.makeComputeCommandEncoder() {
            motion.label = "Move context particles"
            motion.setComputePipelineState(contextMotionPipeline)
            motion.setBuffer(contextBodies, offset: 0, index: 0)
            motion.setBuffer(contextHistory, offset: 0, index: 3)
            motion.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            let gpuSlots = slots
            gpuSlots.withUnsafeBytes { motion.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            motion.dispatchThreads(MTLSize(width: ContextParticles.slotCount, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: ContextParticles.slotCount, height: 1, depth: 1))
            motion.endEncoding()
        }
        return slots
    }

    private func encodeParticles(_ encoder: MTLRenderCommandEncoder, uniforms: Uniforms) {
        var u = uniforms
        encoder.setFragmentBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
        speechHistory.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length: $0.count,index: 3) }
        encoder.setVertexBuffer(fragmentState,offset: 0,index: 4)
        if u.controls.z > 0.0005 || contexts.fragmentsActive(at: simulationTime) {
            encoder.setRenderPipelineState(trailPipeline)
            encoder.setVertexBuffer(particles,offset: 0,index: 0)
            encoder.setVertexBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 1)
            encoder.setVertexBuffer(history,offset: 0,index: 2)
            encoder.drawPrimitives(type: .triangleStrip,vertexStart: 0,
                                   vertexCount: (Self.trailSegments+1)*2,instanceCount: Self.particleCount)
        }
        encoder.setRenderPipelineState(particlePipeline)
        encoder.setVertexBuffer(particles,offset: 0,index: 0)
        encoder.setVertexBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 1)
        encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6,instanceCount: Self.particleCount)
        if contexts.isVisible {
            let slots = contextSlots
            slots.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!,length: $0.count,index: 2) }
            if u.controls.z > 0.0005 {
                encoder.setRenderPipelineState(contextTrailPipeline)
                encoder.setVertexBuffer(contextHistory,offset: 0,index: 3)
                encoder.drawPrimitives(type: .triangleStrip,vertexStart: 0,
                                       vertexCount: (Self.trailSegments+1)*2,instanceCount: ContextParticles.slotCount)
            }
            encoder.setRenderPipelineState(contextPipeline)
            encoder.setVertexBuffer(contextBodies,offset: 0,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 6,instanceCount: ContextParticles.slotCount)
        }
    }

    private func backdropTexture(command: MTLCommandBuffer) -> (MTLTexture, CGRect)? {
        guard transparentBackground, let frame = glassBackdrop?.snapshot(), let cache = textureCache else { return nil }
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil,cache,frame.buffer,nil,.bgra8Unorm_srgb,
            CVPixelBufferGetWidth(frame.buffer),CVPixelBufferGetHeight(frame.buffer),0,&wrapped)
        guard status == kCVReturnSuccess, let wrapped, let texture = CVMetalTextureGetTexture(wrapped) else { return nil }
        // The capture producer can replace its mailbox while this frame is in flight.
        command.addCompletedHandler { _ in withExtendedLifetime((frame.buffer,wrapped)) {} }
        return (texture,frame.viewport)
    }

    func render(command: MTLCommandBuffer, texture: MTLTexture, scale: Float, edr: Float,
                trailOverride: Float? = nil, sparkleOverride: Float? = nil, flashOverride: Float? = nil,
                glassOverride: Float? = nil) {
        var u = uniforms(size: CGSize(width: texture.width,height: texture.height),scale: scale,edr: edr)
        if let trailOverride { u.controls.z = min(1,max(0,trailOverride)) }
        if let sparkleOverride { u.controls.w = min(1,max(0,sparkleOverride)) }
        if let flashOverride { u.speechLight.x = min(Self.maximumFlashFactor,max(0,flashOverride)) }
        if let glassOverride { u.optics.x = min(1,max(0,glassOverride)) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if u.optics.x < 0.0001 && u.optics.y >= 1 {
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.label = "Glass and particles — original optical path"
            encoder.setRenderPipelineState(globePipeline)
            encoder.setFragmentBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            encodeParticles(encoder,uniforms: u)
            encoder.endEncoding()
            return
        }
        if sceneTexture?.width != texture.width || sceneTexture?.height != texture.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: texture.width,height: texture.height,mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget,.shaderRead]
            sceneTexture = device.makeTexture(descriptor: descriptor)
            sceneTexture?.label = "Particles before glass refraction"
        }
        guard let sceneTexture else { return }
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneTexture
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        scenePass.colorAttachments[0].storeAction = .store
        guard let particlesEncoder = command.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        particlesEncoder.label = "Particles and trails inside the glass"
        encodeParticles(particlesEncoder,uniforms: u)
        particlesEncoder.endEncoding()
        let backdrop = u.optics.x > 0.0001 ? backdropTexture(command: command) : nil
        if let (_,rect) = backdrop {
            u.optics.z = 1
            u.backdropUV = SIMD4(Float(rect.minX),Float(rect.minY),Float(rect.width),Float(rect.height))
        }
        guard let lens = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        lens.label = "Refract the globe and live backdrop through curved glass"
        lens.setRenderPipelineState(lensPipeline)
        lens.setFragmentBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
        lens.setFragmentTexture(sceneTexture,index: 0)
        lens.setFragmentTexture(backdrop?.0 ?? sceneTexture,index: 1)
        lens.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
        lens.endEncoding()
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let elapsed = lastTime == 0 ? Double(Self.fixedStep) : min(now-lastTime, 1.0/15.0)
        lastTime = now
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        command.addCompletedHandler { buffer in
            if let error = buffer.error { NSLog("Metal frame failed: %@", error.localizedDescription) }
            semaphore.signal()
        }
        if let speechMeter {
            let snapshot = speechMeter.snapshot()
            targetSpeech = snapshot.level
            targetSpeechWaveform = snapshot.waveform
            targetSpeechSessionActive = snapshot.sessionActive
        }
        #if os(macOS)
        var windowAcceleration = SIMD3<Float>.zero
        if motionInput != nil, let window = view.window {
            windowAcceleration = windowMotion.sample(
                position: SIMD2(Double(window.frame.origin.x), Double(window.frame.origin.y)),
                radius: Double(min(view.bounds.width, view.bounds.height)) * 0.445,
                window: window.windowNumber, at: now)
        }
        sampleMotion(at: now, windowAcceleration: windowAcceleration)
        #else
        sampleMotion(at: now)
        #endif
        accumulator += elapsed
        var steps = 0
        while accumulator >= Double(Self.fixedStep) && steps < 8 {
            step(command: command)
            accumulator -= Double(Self.fixedStep)
            steps += 1
        }
        #if os(macOS)
        let screen = view.window?.screen ?? NSScreen.main
        let available = Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        let refreshRate = screen?.maximumFramesPerSecond ?? 120
        #else
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        let available = Float(screen.currentEDRHeadroom)
        let scale = Float(view.contentScaleFactor)
        let refreshRate = screen.maximumFramesPerSecond
        #endif
        // Follow the actual available headroom, which can change with brightness
        // and power conditions. SDR displays remain a supported fallback.
        headroom += (max(1,available)-headroom)*Float(1-exp(-elapsed*2))
        if view.preferredFramesPerSecond != refreshRate { view.preferredFramesPerSecond = refreshRate }
        render(command: command, texture: drawable.texture, scale: scale, edr: headroom)
        if view.presentsWithTransaction {
            // A floating drag presents its new position and refracted backdrop
            // together. Core Animation requires direct drawable presentation
            // after scheduling; command.present would present asynchronously.
            command.commit()
            command.waitUntilScheduled()
            drawable.present()
        } else {
            command.present(drawable)
            command.commit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
}
