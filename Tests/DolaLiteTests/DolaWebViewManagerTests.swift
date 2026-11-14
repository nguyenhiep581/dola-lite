import Foundation
import Testing
@testable import DolaLite

@Suite struct DolaWebViewManagerTests {
    private func cookie(name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: "v", .domain: domain, .path: "/"])!
    }

    @Test func hasDolaSessionAcceptsSessionCookieOnDolaDomain() {
        #expect(DolaWebViewManager.hasDolaSession([cookie(name: "sessionid", domain: ".dola.com")]))
    }

    @Test func hasDolaSessionRejectsNonSessionCookies() {
        #expect(!DolaWebViewManager.hasDolaSession([cookie(name: "ttwid", domain: ".dola.com")]))
    }

    @Test func hasDolaSessionRejectsOtherDomains() {
        #expect(!DolaWebViewManager.hasDolaSession([cookie(name: "sessionid", domain: ".example.com")]))
    }

    @Test func hasDolaSessionMatchesBothWwwAndBareSuffixDomains() {
        #expect(DolaWebViewManager.hasDolaSession([cookie(name: "sid_guard", domain: "www.dola.com")]))
        #expect(DolaWebViewManager.hasDolaSession([cookie(name: "sessionid_ss", domain: ".dola.com")]))
        #expect(DolaWebViewManager.hasDolaSession([
            cookie(name: "ttwid", domain: ".dola.com"),
            cookie(name: "sessionid", domain: "www.dola.com"),
        ]))
    }
}
