import NuboCore
import XCTest

final class DisplayModeSelectionTests: XCTestCase {
    func testExactModeWinsAndInvalidModesAreRejected() {
        XCTAssertEqual(DisplayModeSelection.score(width: 1366, height: 1024, targetWidth: 1366, targetHeight: 1024), 0)
        XCTAssertEqual(DisplayModeSelection.score(width: 0, height: 1024, targetWidth: 1366, targetHeight: 1024), .infinity)
        XCTAssertLessThan(DisplayModeSelection.score(width: 1280, height: 960, targetWidth: 1366, targetHeight: 1024),
                          DisplayModeSelection.score(width: 1920, height: 1080, targetWidth: 1366, targetHeight: 1024))
    }
}
