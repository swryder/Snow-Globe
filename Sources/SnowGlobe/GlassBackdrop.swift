import CoreGraphics
import CoreVideo
import Foundation

/// Latest local image behind a globe. The package never captures the screen itself.
/// Supply immutable BGRA buffers encoded in Display P3 with the sRGB transfer curve.
public final class GlassBackdrop: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var viewport = CGRect(x: 0,y: 0,width: 1,height: 1)

    public init() {}

    public func store(_ pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { clear(); return }
        lock.lock(); buffer = pixelBuffer; lock.unlock()
    }

    /// The globe's rectangular viewport in normalized image coordinates, top-left origin.
    /// Updating this separately keeps the lens aligned during a drag over a static desktop.
    public func updateViewport(_ rect: CGRect) {
        guard [rect.origin.x,rect.origin.y,rect.width,rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { clear(); return }
        lock.lock(); viewport = rect; lock.unlock()
    }

    public func clear() { lock.lock(); buffer = nil; lock.unlock() }

    func snapshot() -> (buffer: CVPixelBuffer, viewport: CGRect)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer,viewport)
    }
}
