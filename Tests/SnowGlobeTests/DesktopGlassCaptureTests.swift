#if os(macOS)
import XCTest
@testable import SnowGlobe

final class DesktopGlassCaptureTests: XCTestCase {
    func testViewportIsNormalizedWithTopLeftOrigin() {
        let screen = NSRect(x: 0, y: 0, width: 2000, height: 1000)
        // A 200 × 200 lens whose bottom-left corner is 100 pt right of and 100 pt above the screen's.
        let viewport = DesktopGlassCapture.viewport(of: NSRect(x: 100, y: 100, width: 200, height: 200), onScreen: screen)
        XCTAssertEqual(viewport.origin.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(viewport.origin.y, 0.7, accuracy: 1e-9)
        XCTAssertEqual(viewport.width, 0.1, accuracy: 1e-9)
        XCTAssertEqual(viewport.height, 0.2, accuracy: 1e-9)
    }

    func testViewportOnADisplayLeftOfAndAboveTheMainOne() {
        let screen = NSRect(x: -1440, y: 200, width: 1440, height: 900)
        // A lens in the display's top-left corner.
        let viewport = DesktopGlassCapture.viewport(of: NSRect(x: -1440, y: 860, width: 240, height: 240), onScreen: screen)
        XCTAssertEqual(viewport.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(viewport.origin.y, 0, accuracy: 1e-9)
        XCTAssertEqual(viewport.width, 240.0 / 1440, accuracy: 1e-9)
        XCTAssertEqual(viewport.height, 240.0 / 900, accuracy: 1e-9)
    }
}
#endif
