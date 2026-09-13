#if os(macOS)
import AppKit
import Combine
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// A live, memory-only desktop backdrop for a floating globe's glass (macOS).
///
/// Streams the display under the globe's window through ScreenCaptureKit, leaving the globe's own
/// window out so it never refracts itself, and hands each complete frame to `backdrop`. It captures
/// no audio, keeps only the latest frame, saves nothing and sends nothing. It needs Screen Recording
/// access; without it `state` is `.permissionNeeded` and the globe keeps particle refraction and
/// ordinary transparency.
///
/// Pass `backdrop` to `SnowGlobeView(glassBackdrop:)` and call `update(window:active:lens:)` when
/// the floating globe is shown, moves to another window, or is hidden. Window moves and display
/// changes are followed automatically. Asking for access is the app's decision: `enable()` asks and
/// opens System Settings, and is meant for an explicit control; nothing else here prompts.
@MainActor
public final class DesktopGlassCapture: ObservableObject {
    public enum State: Equatable, Sendable { case off, permissionNeeded, starting, live, failed(String) }

    @Published public private(set) var state: State = .off
    public let backdrop = GlassBackdrop()

    private weak var window: NSWindow?
    private var lens: NSRect?
    private var wanted = false
    private var displayID: CGDirectDisplayID?
    private var generation = 0
    // Written only on the main actor; `deinit` reads them once nothing else holds the capture.
    private nonisolated(unsafe) var stream: SCStream?
    private nonisolated(unsafe) var sink: DesktopFrameSink?
    private nonisolated(unsafe) var startTask: Task<Void, Never>?
    private nonisolated(unsafe) var firstFrameTimeout: Task<Void, Never>?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    public var message: String {
        switch state {
        case .off: return "Particle refraction"
        case .permissionNeeded:
            return "Desktop refraction is off. Allow Screen Recording access for \(Self.appName), then reopen the app if macOS asks."
        case .starting: return "Preparing desktop refraction…"
        case .live: return "Desktop refraction is live · processed locally"
        case .failed(let message): return message
        }
    }

    public var needsAction: Bool {
        if case .permissionNeeded = state { return true }
        if case .failed = state { return true }
        return false
    }

    public init() {
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification,
                     NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let moved = note.object as? NSWindow
                let screensChanged = note.name == NSApplication.didChangeScreenParametersNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let moved, moved !== self.window { return }
                    if screensChanged { self.stop(); self.setState(.off) }
                    self.refresh()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        startTask?.cancel()
        firstFrameTimeout?.cancel()
        sink?.invalidate()
        if let stream { Task { try? await stream.stopCapture() } }
    }

    /// Follow `window` while `active`; stop otherwise. `lens` is the globe's rectangle in the
    /// window's coordinates when the globe does not fill its window (a caption under it, for
    /// example); nil means the whole window.
    public func update(window: NSWindow?, active: Bool, lens: NSRect? = nil) {
        self.window = window
        self.lens = lens
        wanted = active
        refresh()
    }

    /// Asks for Screen Recording access, opening System Settings when macOS will not prompt.
    public func enable() {
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            setState(.permissionNeeded)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        stop()
        setState(.off)
        refresh()
    }

    /// A rectangle in AppKit screen coordinates (bottom-left origin) as `GlassBackdrop` wants it:
    /// normalized to the display image, top-left origin.
    nonisolated static func viewport(of rect: NSRect, onScreen screen: NSRect) -> CGRect {
        CGRect(x: (rect.minX - screen.minX) / screen.width,
               y: (screen.maxY - rect.maxY) / screen.height,
               width: rect.width / screen.width,
               height: rect.height / screen.height)
    }

    nonisolated static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "this app"
    }

    private func setState(_ next: State) { if state != next { state = next } }

    fileprivate func firstFrameArrived(generation token: Int) {
        guard token == generation else { return }
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        setState(.live)
    }

    fileprivate func streamStopped(generation token: Int, reason: String) {
        guard token == generation else { return }
        stop()
        setState(.failed("Desktop refraction stopped: \(reason)"))
    }

    private func refresh() {
        guard wanted, let window, let screen = window.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            stop(); setState(.off); return
        }
        // macOS permission is the source of truth. A second, hidden preference
        // used to leave refraction off even after screen access was allowed.
        guard CGPreflightScreenCaptureAccess() else {
            stop(); setState(.permissionNeeded); return
        }
        let id = number.uint32Value
        if displayID != id { stop() }
        let lensOnScreen = lens.map { window.convertToScreen($0) } ?? window.frame
        backdrop.updateViewport(Self.viewport(of: lensOnScreen, onScreen: screen.frame))
        guard stream == nil, startTask == nil else { return }
        if case .failed = state { return }
        displayID = id
        setState(.starting)
        let token = generation
        let windowID = CGWindowID(window.windowNumber)
        let backingScale = screen.backingScaleFactor
        let streamName = "\(Self.appName) desktop refraction"
        startTask = Task { [weak self] in
            guard let self else { return }
            var candidate: SCStream?
            var output: DesktopFrameSink?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !Task.isCancelled, token == self.generation else { return }
                guard let display = content.displays.first(where: { $0.displayID == id }),
                      let overlay = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw CaptureFailure("The floating globe's display is unavailable. Retry desktop refraction.")
                }
                let filter = SCContentFilter(display: display, excludingWindows: [overlay])
                let config = SCStreamConfiguration()
                // Keep one display available while dragging so coordinates update instantly,
                // even when a static desktop produces no new frames. Keep no frame history.
                let scale = min(backingScale, 4096 / Double(max(display.width, display.height)))
                config.width = max(1, Int(Double(display.width) * scale))
                config.height = max(1, Int(Double(display.height) * scale))
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 3
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.displayP3
                config.showsCursor = false
                config.capturesAudio = false
                config.streamName = streamName
                let sink = DesktopFrameSink(backdrop: self.backdrop, owner: self, generation: token)
                output = sink
                let capture = SCStream(filter: filter, configuration: config, delegate: sink)
                candidate = capture
                try capture.addStreamOutput(sink, type: .screen,
                                            sampleHandlerQueue: DispatchQueue(label: "SnowGlobe.desktop", qos: .userInteractive))
                self.stream = capture
                self.sink = sink
                try await capture.startCapture()
                guard !Task.isCancelled, token == self.generation else {
                    sink.invalidate(); try? await capture.stopCapture(); return
                }
                self.stream = capture
                self.sink = sink
                self.startTask = nil
                // Starting a stream doesn't prove that any usable screen pixels
                // arrived. Report Live only after the first complete BGRA frame.
                if self.state == .starting {
                    self.firstFrameTimeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self, token == self.generation, self.state == .starting else { return }
                        self.stop()
                        self.setState(.failed("No desktop image received. Check Screen Recording access, then retry."))
                    }
                }
            } catch {
                output?.invalidate()
                if let candidate { try? await candidate.stopCapture() }
                guard token == self.generation else { return }
                self.stop()
                self.setState(.failed("Desktop refraction unavailable: \(error.localizedDescription)"))
            }
        }
    }

    private func stop() {
        generation += 1
        startTask?.cancel(); startTask = nil
        firstFrameTimeout?.cancel(); firstFrameTimeout = nil
        sink?.invalidate(); sink = nil
        let previous = stream
        stream = nil; displayID = nil
        backdrop.clear()
        if let previous { Task { try? await previous.stopCapture() } }
    }
}

private struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Receives frames on ScreenCaptureKit's queue. `active` is guarded by the lock; the capture it
/// reports to is reached only on the main actor.
private final class DesktopFrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var deliveredFirstFrame = false
    private let backdrop: GlassBackdrop
    private weak var owner: DesktopGlassCapture?
    private let generation: Int

    init(backdrop: GlassBackdrop, owner: DesktopGlassCapture, generation: Int) {
        self.backdrop = backdrop
        self.owner = owner
        self.generation = generation
    }

    func invalidate() { lock.lock(); active = false; lock.unlock() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let metadata = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = metadata.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sample.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        backdrop.store(pixels)
        let first = !deliveredFirstFrame
        deliveredFirstFrame = true
        lock.unlock()
        if first {
            let owner = self.owner, generation = self.generation
            Task { @MainActor in owner?.firstFrameArrived(generation: generation) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let report = active; lock.unlock()
        guard report else { return }
        let owner = self.owner, generation = self.generation, reason = error.localizedDescription
        Task { @MainActor in owner?.streamStopped(generation: generation, reason: reason) }
    }
}

#endif
