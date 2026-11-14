// XCTest chỉ khả dụng khi cài đầy đủ Xcode (không có trong Command Line Tools).
// canImport để `swift build` vẫn pass trên máy chỉ có CLT; test tự kích hoạt khi có Xcode.
#if canImport(XCTest)
import XCTest
@testable import DolaLite

final class ConfigTests: XCTestCase {
    func testConfigConstants() throws {
        XCTAssertEqual(Config.targetLanguage, "vi")
        XCTAssertEqual(Config.chatURL.absoluteString, "https://www.dola.com/chat/")
        XCTAssertEqual(Config.selectionDebounceMs, 300)
        XCTAssertEqual(Config.minSelectionLength, 2)
        XCTAssertEqual(Config.maxSelectionLength, 10_000)
        XCTAssertEqual(Config.streamTimeoutSec, 60)
        XCTAssertEqual(Config.pollIntervalMs, 0.3)
    }
}
#endif
