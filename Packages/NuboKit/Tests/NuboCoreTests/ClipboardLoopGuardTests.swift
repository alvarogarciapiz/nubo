import NuboCore
import XCTest

final class ClipboardLoopGuardTests: XCTestCase {
    func testRemoteWriteIsNotEchoedButLaterLocalWriteIsSent() async {
        let guarder = ClipboardLoopGuard()
        await guarder.markRemoteText("hello")

        let first = await guarder.shouldSendLocalText("hello")
        let second = await guarder.shouldSendLocalText("hello")
        XCTAssertFalse(first)
        XCTAssertTrue(second)
    }
}
