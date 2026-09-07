import SwiftUI
import SnowGlobe
import MetalKit

/// Move a single hosting view between the controls and an independent panel.
/// Its SwiftUI identity, Metal renderer, and particle history survive each move.
struct GlobeSurface: NSViewRepresentable {
    let globe: SnowGlobeView
    let isFloating: Bool
    let glassEffect: Double
    let capture: DesktopGlassCapture

    func makeCoordinator() -> Coordinator { Coordinator(globe: globe) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.host.rootView = globe
        coordinator.isFloating = isFloating
        coordinator.glassEffect = glassEffect
        coordinator.capture = capture
        // Reparent and resize after SwiftUI has finished its current layout.
        DispatchQueue.main.async { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.present(in: view)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator {
        let host: NSHostingView<SnowGlobeView>
        private(set) var panel: NSPanel?
        var isFloating = false
        var glassEffect = 0.45
        weak var capture: DesktopGlassCapture?
        private var presentedFloating = false
        private var embeddedWindowFrame: NSRect?
        private var valid = true

        init(globe: SnowGlobeView) {
            host = NSHostingView(rootView: globe)
            host.sizingOptions = []
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
        }

        func present(in container: NSView) {
            guard valid, let controls = container.window else { return }
            if isFloating {
                let floating = panel ?? makePanel(near: controls)
                // Glass opacity is composited in Metal so desktop refraction does not
                // double-expose the undistorted screen through native window alpha.
                floating.alphaValue = 1
                floating.ignoresMouseEvents = false
                if !presentedFloating {
                    embeddedWindowFrame = controls.frame
                    moveHost(to: floating.contentView!)
                    floating.orderFront(nil)
                    resizeControls(controls, floating: true)
                }
            } else {
                moveHost(to: container)
                panel?.orderOut(nil)
                if presentedFloating { resizeControls(controls, floating: false) }
            }
            presentedFloating = isFloating
            capture?.update(window: isFloating ? panel : nil,
                            active: isFloating && glassEffect > 0.0001)
        }

        private func makePanel(near controls: NSWindow) -> NSPanel {
            let visible = (controls.screen ?? NSScreen.main)?.visibleFrame ?? controls.frame
            let side = min(480, min(visible.width,visible.height)*0.75)
            // Place the globe to the right of the compact controls when possible.
            let origin = NSPoint(x: min(visible.maxX-side, max(visible.minX,controls.frame.minX+640)),
                                 y: min(visible.maxY-side, max(visible.minY,controls.frame.midY-side/2)))
            let panel = FloatingGlobePanel(contentRect: NSRect(origin: origin, size: NSSize(width: side,height: side)),
                                           styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
            panel.title = "Floating Snow Globe"
            panel.identifier = NSUserInterfaceItemIdentifier("snow-globe-floating")
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.fullScreenAuxiliary]
            let content = NSView(frame: NSRect(origin: .zero,size: panel.frame.size))
            panel.contentView = content
            let drag = GlobeDragView(frame: content.bounds)
            drag.autoresizingMask = [.width, .height]
            content.addSubview(drag)
            self.panel = panel
            return panel
        }

        private func moveHost(to destination: NSView) {
            guard host.superview !== destination else { return }
            host.removeFromSuperview()
            host.frame = destination.bounds
            host.autoresizingMask = [.width, .height]
            destination.addSubview(host, positioned: .below, relativeTo: destination.subviews.first)
        }

        private func resizeControls(_ controls: NSWindow, floating: Bool) {
            controls.title = floating ? "Snow Globe Controls" : "Snow Globe"
            controls.titleVisibility = floating ? .visible : .hidden
            controls.contentMinSize = NSSize(width: 540,height: floating ? 740 : 790)
            if floating {
                let top = controls.frame.maxY
                controls.setContentSize(NSSize(width: 620,height: 770))
                controls.setFrameOrigin(NSPoint(x: controls.frame.minX,y: top-controls.frame.height))
            } else if let frame = embeddedWindowFrame {
                controls.setFrame(frame,display: true)
            }
        }

        func invalidate() {
            valid = false
            panel?.contentView?.subviews.compactMap { $0 as? GlobeDragView }.forEach { $0.cancelDrag() }
            capture?.update(window: nil,active: false)
            panel?.orderOut(nil)
            host.removeFromSuperview()
            panel?.close()
            panel = nil
        }
    }
}

private final class FloatingGlobePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Only the visible sphere starts a drag; the transparent corners have no handle.
private final class GlobeDragView: NSView {
    private var dragStart: (pointer: NSPoint, window: NSPoint)?
    private var dragFrames: GlobeDragFrames?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point,from: superview)
        let radius = min(bounds.width,bounds.height)*0.445
        return hypot(local.x-bounds.midX,local.y-bounds.midY) <= radius ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        cancelDrag()
        dragStart = (screenPointer(event),window.frame.origin)
        if let content = window.contentView, let metal = metalView(in: content) {
            dragFrames = GlobeDragFrames(view: metal,window: window) { [weak self] in self?.dragFrames = nil }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let pointer = screenPointer(event)
        let origin = NSPoint(x: start.window.x+pointer.x-start.pointer.x,
                             y: start.window.y+pointer.y-start.pointer.y)
        if let dragFrames { dragFrames.pendingOrigin = origin }
        else { window.setFrameOrigin(origin) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { mouseDragged(with: event) }
        dragStart = nil
        dragFrames?.finishAfterFrame = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelDrag()
        super.viewWillMove(toWindow: newWindow)
    }

    func cancelDrag() {
        dragStart = nil
        dragFrames?.cancel()
        dragFrames = nil
    }

    private func screenPointer(_ event: NSEvent) -> NSPoint {
        // Real mouse events retain their original Quartz screen position.
        // Converting queued window-relative coordinates with the window's NEW
        // frame feeds its last movement back into the next movement.
        guard let location = event.cgEvent?.location, let primary = NSScreen.screens.first else {
            return NSEvent.mouseLocation
        }
        return NSPoint(x: location.x,y: primary.frame.maxY-location.y)
    }

    private func metalView(in view: NSView) -> MTKView? {
        if let metal = view as? MTKView { return metal }
        for child in view.subviews { if let metal = metalView(in: child) { return metal } }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: bounds.width*0.055,dy: bounds.height*0.055),cursor: .openHand)
    }
}

/// Keep panel placement and the refracted pixels on the same display tick.
/// Coalescing input avoids moving the window ahead of an older Metal drawable.
private final class GlobeDragFrames: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private weak var window: NSWindow?
    private let original: MTKViewDelegate
    private let previousTransactionMode: Bool
    private var onFinish: (() -> Void)?
    var pendingOrigin: NSPoint?
    var finishAfterFrame = false

    init?(view: MTKView, window: NSWindow, onFinish: @escaping () -> Void) {
        guard let original = view.delegate, !view.isPaused else { return nil }
        self.view = view; self.window = window; self.original = original
        previousTransactionMode = view.presentsWithTransaction
        self.onFinish = onFinish
        super.init()
        view.presentsWithTransaction = true
        view.delegate = self
    }

    func draw(in view: MTKView) {
        guard let window, view.window === window else {
            cancel(); original.draw(in: view); return
        }
        // Acquire a presentation surface before changing position. Waiting for
        // a busy drawable after moving would expose the previous lens image.
        guard view.currentDrawable != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let origin = pendingOrigin {
            pendingOrigin = nil
            window.setFrameOrigin(origin)
        }
        original.draw(in: view)
        CATransaction.commit()
        if finishAfterFrame { cancel() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        original.mtkView(view,drawableSizeWillChange: size)
    }

    func cancel() {
        if let view, view.delegate === self {
            view.delegate = original
            view.presentsWithTransaction = previousTransactionMode
        }
        let finished = onFinish
        onFinish = nil
        finished?()
    }
}
