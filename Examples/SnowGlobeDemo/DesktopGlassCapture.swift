import AppKit
import Combine
import ScreenCaptureKit
import SnowGlobe

/// A local, memory-only backdrop for refraction. Audio and the globe itself are excluded.
@MainActor
final class DesktopGlassCapture: ObservableObject {
    enum State: Equatable { case off, permissionNeeded, starting, live, failed(String) }
    @Published private(set) var state: State = .off
    let backdrop = GlassBackdrop()
    private weak var window: NSWindow?
    private var wanted = false
    private var stream: SCStream?
    private var sink: DesktopFrameSink?
    private var startTask: Task<Void,Never>?
    private var firstFrameTimeout: Task<Void,Never>?
    private var displayID: CGDirectDisplayID?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    var message: String {
        switch state {
        case .off: return "Particle refraction"
        case .permissionNeeded: return "Desktop refraction is off. Allow Screen Recording access for Snow Globe, then reopen the app if macOS asks."
        case .starting: return "Preparing desktop refraction…"
        case .live: return "Desktop refraction is live · processed locally"
        case .failed(let message): return message
        }
    }
    var needsAction: Bool {
        if case .permissionNeeded = state { return true }
        if case .failed = state { return true }
        return false
    }

    init() {
        for name in [NSWindow.didMoveNotification,NSWindow.didChangeScreenNotification,
                     NSApplication.didChangeScreenParametersNotification,NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name,object: nil,queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let moved = note.object as? NSWindow, moved !== self.window { return }
                    if note.name == NSApplication.didChangeScreenParametersNotification { self.stop(); self.setState(.off) }
                    self.refresh()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil,queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
    }

    private func setState(_ next: State) { if state != next { state = next } }

    func update(window: NSWindow?, active: Bool) {
        self.window = window
        wanted = active
        refresh()
    }

    /// Called only by the panel's explicit Enable button. No automatic permission prompts.
    func enable() {
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            setState(.permissionNeeded)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        stop()
        setState(.off)
        refresh()
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
        let frame = screen.frame
        // AppKit uses a bottom-left origin; captured image rows start at the top.
        backdrop.updateViewport(CGRect(x: (window.frame.minX-frame.minX)/frame.width,
            y: (frame.maxY-window.frame.maxY)/frame.height,
            width: window.frame.width/frame.width,height: window.frame.height/frame.height))
        guard stream == nil, startTask == nil else { return }
        if case .failed = state { return }
        displayID = id
        setState(.starting)
        let token = generation
        let windowID = CGWindowID(window.windowNumber)
        let backingScale = screen.backingScaleFactor
        startTask = Task { [weak self] in
            guard let self else { return }
            var candidate: SCStream?
            var output: DesktopFrameSink?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly: false)
                guard !Task.isCancelled, token == self.generation else { return }
                guard let display = content.displays.first(where: { $0.displayID == id }),
                      let overlay = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw CaptureFailure("The floating globe's display is unavailable. Retry desktop refraction.")
                }
                let filter = SCContentFilter(display: display,excludingWindows: [overlay])
                let config = SCStreamConfiguration()
                // Keep one display available while dragging so coordinates update instantly,
                // even when a static desktop produces no new frames. Keep no frame history.
                let scale = min(backingScale,4096/Double(max(display.width,display.height)))
                config.width = max(1,Int(Double(display.width)*scale))
                config.height = max(1,Int(Double(display.height)*scale))
                config.minimumFrameInterval = CMTime(value: 1,timescale: 30)
                config.queueDepth = 3
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.displayP3
                config.showsCursor = false
                config.capturesAudio = false
                config.streamName = "Snow Globe desktop refraction"
                let sink = DesktopFrameSink(backdrop: self.backdrop, firstFrame: { [weak self] in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        self.firstFrameTimeout?.cancel(); self.firstFrameTimeout = nil
                        self.setState(.live)
                    }
                }) { [weak self] error in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        self.stop(); self.setState(.failed("Desktop refraction stopped: \(error.localizedDescription)"))
                    }
                }
                output = sink
                let capture = SCStream(filter: filter,configuration: config,delegate: sink)
                candidate = capture
                try capture.addStreamOutput(sink,type: .screen,sampleHandlerQueue: DispatchQueue(label: "SnowGlobe.desktop",qos: .userInteractive))
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

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        startTask?.cancel()
        firstFrameTimeout?.cancel()
        sink?.invalidate()
        if let stream { Task { try? await stream.stopCapture() } }
    }
}

private struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class DesktopFrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private var active = true
    private var deliveredFirstFrame = false
    private let backdrop: GlassBackdrop
    private let firstFrame: () -> Void
    private let failed: (Error) -> Void

    init(backdrop: GlassBackdrop, firstFrame: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        self.backdrop = backdrop; self.firstFrame = firstFrame; self.failed = failed
    }
    func invalidate() { lock.lock(); active = false; lock.unlock() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let metadata = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = metadata.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sample.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        backdrop.store(pixels)
        let first = !deliveredFirstFrame
        deliveredFirstFrame = true
        lock.unlock()
        if first { firstFrame() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let report = active; lock.unlock()
        if report { failed(error) }
    }
}
