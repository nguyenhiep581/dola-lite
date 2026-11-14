import Foundation
import Testing
@testable import DolaLite

@Suite struct SessionImporterTests {
    private func cdp(name: String?, value: String?, domain: String?,
                     path: String? = "/", expires: Double? = nil,
                     httpOnly: Bool? = nil, secure: Bool? = nil) -> SessionImporter.CDPCookie {
        .init(name: name, value: value, domain: domain, path: path,
              expires: expires, httpOnly: httpOnly, secure: secure)
    }

    @Test func mapsDotDomainCookieWithAllFields() throws {
        let http = try #require(SessionImporter.mapToHTTPCookie(
            cdp(name: "sessionid", value: "v", domain: ".dola.com",
                path: "/", expires: 1_800_000_000, httpOnly: true, secure: true)))
        #expect(http.name == "sessionid")
        #expect(http.value == "v")
        #expect(http.domain == ".dola.com")
        #expect(http.path == "/")
        #expect(http.isSecure)
        #expect(http.expiresDate == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func mapsNoDotDomainVerbatimAndDefaultsPath() throws {
        let http = try #require(SessionImporter.mapToHTTPCookie(
            cdp(name: "sid_guard", value: "v", domain: "www.dola.com", path: nil)))
        #expect(http.domain == "www.dola.com")   // giữ nguyên no-dot
        #expect(http.path == "/")
        #expect(http.expiresDate == nil)          // không expires → session cookie
    }

    @Test func negativeExpiresTreatedAsSessionCookie() throws {
        let http = try #require(SessionImporter.mapToHTTPCookie(
            cdp(name: "sessionid", value: "v", domain: ".dola.com", expires: -1)))
        #expect(http.expiresDate == nil)
    }

    @Test func missingRequiredFieldsReturnNil() {
        #expect(SessionImporter.mapToHTTPCookie(cdp(name: nil, value: "v", domain: ".dola.com")) == nil)
        #expect(SessionImporter.mapToHTTPCookie(cdp(name: "n", value: nil, domain: ".dola.com")) == nil)
        #expect(SessionImporter.mapToHTTPCookie(cdp(name: "n", value: "v", domain: nil)) == nil)
    }
}
