import NuboCore
import NuboInput
import NuboProtocol
import XCTest

final class CoordinateMapperTests: XCTestCase {
    func testAspectFitMappingRejectsLetterboxAndAccountsForZoom() {
        let display = DisplayDescriptor(id: .init(rawValue: 7), name: "Retina", pixelWidth: 3000, pixelHeight: 2000, scale: 2, originX: -1500, originY: -100, isPrimary: false)
        let mapper = CoordinateMapper(display: display)
        XCTAssertNil(mapper.desktopPoint(viewPoint: .init(x: 1, y: 400), viewportWidth: 1600, viewportHeight: 800))
        XCTAssertEqual(mapper.desktopPoint(viewPoint: .init(x: 800, y: 400), viewportWidth: 1600, viewportHeight: 800), .init(x: -750, y: 400))
        XCTAssertEqual(mapper.desktopPoint(viewPoint: .init(x: 200, y: 400), viewportWidth: 1600, viewportHeight: 800, zoom: 2), .init(x: -1125, y: 400))
        XCTAssertNil(mapper.desktopPoint(viewPoint: .init(x: .nan, y: 0), viewportWidth: 1600, viewportHeight: 800))
    }
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
