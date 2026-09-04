import NuboCore
import NuboInput
import NuboProtocol
import XCTest

final class CoordinateMapperTests: XCTestCase {
    func testMapsNormalizedPointIntoNegativeOriginDisplay() {
        let display = DisplayDescriptor(
            id: DisplayID(rawValue: 2),
            name: "Left display",
            pixelWidth: 3_840,
            pixelHeight: 2_160,
            scale: 2,
            originX: -1_920,
            originY: 0,
            isPrimary: false
        )
        let result = CoordinateMapper(display: display).desktopPoint(normalized: Point(x: 0.5, y: 0.5))
        XCTAssertEqual(result, Point(x: -960, y: 540))
    }

    func testClampsAbsoluteInput() {
        let display = DisplayDescriptor(id: .init(rawValue: 1), name: "Main", pixelWidth: 100, pixelHeight: 50, scale: 1, originX: 0, originY: 0, isPrimary: true)
        let result = CoordinateMapper(display: display).desktopPoint(normalized: Point(x: 2, y: -1))
        XCTAssertEqual(result, Point(x: 100, y: 0))
    }
}
