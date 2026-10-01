import MetalKit
import SwiftUI

/// A resizable Metal particle indicator for macOS and iOS.
/// Keep the same view identity and SpeechMeter instance across updates to preserve motion history.
@MainActor
public struct SnowGlobeView: View {
    private let activity: Float
    private let isConnected: Bool
    private let configuration: SnowGlobeConfiguration
    private let speechMeter: SpeechMeter?
    private let glassBackdrop: GlassBackdrop?
    private let motion: GlobeMotion?
    private let contextItems: [SnowGlobeContextItem]
    private let onError: ((Error) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var failure: String?

    /// - Parameters:
    ///   - activity: Effort from 0 (idle) to 1 (maximum). Large changes respond faster.
    ///   - isConnected: False lets particles fall and settle; true restores circulation.
    ///   - configuration: Shared, tuned defaults unless explicitly overridden.
    ///   - speechMeter: A persistent, thread-safe mailbox fed using actual audio playback time.
    ///   - glassBackdrop: Optional local image for refraction behind a transparent globe.
    ///   - motion: Optional physical input; also enables automatic window inertia on macOS.
    ///   - contextItems: Files the agent can see. Each pending item is a large particle,
    ///     up to six; committing an item breaks its particle up into the stream.
    ///   - onError: Called on the main queue if Metal initialization fails.
    public init(activity: Float = 0, isConnected: Bool = true,
                configuration: SnowGlobeConfiguration = .default,
                speechMeter: SpeechMeter? = nil, glassBackdrop: GlassBackdrop? = nil,
                motion: GlobeMotion? = nil,
                contextItems: [SnowGlobeContextItem] = [],
                onError: ((Error) -> Void)? = nil) {
        self.activity = activity
        self.isConnected = isConnected
        self.configuration = configuration
        self.speechMeter = speechMeter
        self.glassBackdrop = glassBackdrop
        self.motion = motion
        self.contextItems = contextItems
        self.onError = onError
    }

    public var body: some View {
        let dark = configuration.appearance == .dark ||
            (configuration.appearance == .automatic && colorScheme == .dark)
        ZStack {
            MetalGlobe(activity: activity, isConnected: isConnected,
                       configuration: configuration.normalized, dark: dark, speechMeter: speechMeter,
                       glassBackdrop: glassBackdrop, motion: motion, contextItems: contextItems) { error in
                failure = error.localizedDescription
                onError?(error)
            }
            if let failure {
                ContentUnavailableView("Metal renderer unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Snow Globe activity")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let state = isConnected ? "\(Int(sanitized(activity, in: 0...1, fallback: 0)*100)) percent" : "Disconnected"
        let attached = Set(contextItems.filter { $0.state == .pending }.map(\.id)).count
        switch attached {
        case 0: return state
        case 1: return "\(state), 1 file attached"
        default: return "\(state), \(attached) files attached"
        }
    }
}

@MainActor
private struct MetalGlobe {
    let activity: Float
    let isConnected: Bool
    let configuration: SnowGlobeConfiguration
    let dark: Bool
    let speechMeter: SpeechMeter?
    let glassBackdrop: GlassBackdrop?
    let motion: GlobeMotion?
    let contextItems: [SnowGlobeContextItem]
    let onError: (Error) -> Void

    final class Coordinator {
        var renderer: ParticleRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeView(coordinator: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero)
        do {
            let renderer = try ParticleRenderer(initialDark: dark ? 1 : 0,
                initialDisc: configuration.shape == .disc ? 1 : 0,
                initialIdleSpeed: configuration.idleSpeed,
                initialDensity: Float(configuration.particleCount)/ParticleRenderer.baseParticleCount,
                initialSize: configuration.particleSize, initialTrailLength: configuration.trailLength)
            coordinator.renderer = renderer
            update(renderer)
            view.device = renderer.device
            view.colorPixelFormat = .rgba16Float
            view.depthStencilPixelFormat = .invalid
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 120
            view.enableSetNeedsDisplay = false
            view.isPaused = false
            view.delegate = renderer
            #if os(macOS)
            view.wantsLayer = true
            #endif
            if let layer = view.layer as? CAMetalLayer {
                layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                layer.wantsExtendedDynamicRangeContent = true
                layer.isOpaque = !configuration.transparentBackground
            }
            updateBackground(view)
        } catch {
            view.isPaused = true
            DispatchQueue.main.async { onError(error) }
        }
        return view
    }

    func update(_ renderer: ParticleRenderer) {
        renderer.targetGlassEffect = configuration.glassEffect
        renderer.opacity = configuration.opacity
        renderer.glassBackdrop = glassBackdrop
        renderer.motionInput = motion
        renderer.motionSensitivity = configuration.motionSensitivity
        renderer.transparentBackground = configuration.transparentBackground
        renderer.speechMeter = speechMeter
        if speechMeter == nil {
            renderer.targetSpeech = .zero
            renderer.targetSpeechWaveform = []
            renderer.targetSpeechSessionActive = false
        }
        renderer.targetSpeechExpression = configuration.speechExpression
        renderer.targetLiveWaveform = configuration.speechMode == .live ? 1 : 0
        renderer.targetFlashFactor = configuration.flashFactor
        renderer.targetActivity = sanitized(activity, in: 0...1, fallback: 0)
        renderer.targetConnected = isConnected
        renderer.targetContextItems = contextItems
        renderer.targetDark = dark ? 1 : 0
        renderer.targetDisc = configuration.shape == .disc ? 1 : 0
        renderer.targetDensity = Float(configuration.particleCount)/ParticleRenderer.baseParticleCount
        renderer.targetSize = configuration.particleSize
        renderer.targetIdleSpeed = configuration.idleSpeed
        renderer.targetTrailLength = configuration.trailLength
        renderer.targetSpeakingTrailLength = configuration.speakingTrailLength
    }

    static func dismantle(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }

    func updateBackground(_ view: MTKView) {
        #if os(macOS)
        view.layer?.isOpaque = !configuration.transparentBackground && configuration.opacity >= 1
        #else
        view.layer.isOpaque = !configuration.transparentBackground && configuration.opacity >= 1
        view.isOpaque = !configuration.transparentBackground && configuration.opacity >= 1
        view.backgroundColor = view.isOpaque ? .black : .clear
        #endif
    }
}

#if os(macOS)
extension MetalGlobe: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeView(coordinator: context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) {
        updateBackground(view)
        if let renderer = context.coordinator.renderer { update(renderer) }
    }
    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) { dismantle(view, coordinator: coordinator) }
}
#elseif os(iOS)
extension MetalGlobe: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeView(coordinator: context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) {
        updateBackground(view)
        if let renderer = context.coordinator.renderer { update(renderer) }
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) { dismantle(view, coordinator: coordinator) }
}
#endif
