import Testing
@testable import DolaLite

@Suite struct ConfigTests {
    @Test func chatURLPointsAtDolaChat() {
        #expect(Config.chatURL.host == "www.dola.com")
        #expect(Config.chatURL.absoluteString.hasPrefix("https://www.dola.com/chat"))
    }

    @Test func selectionLimitAcceptsReasonableText() {
        #expect(Config.maxSelectionLength >= 1000)
        #expect(Config.minSelectionLength >= 1)
    }
}
