import BlockingCore
import Testing

@Suite("DomainSanitizer")
struct DomainSanitizerTests {
    @Test("normalizes URLs and strips paths")
    func normalizesUrlHost() {
        let normalized = DomainSanitizer.normalized("https://YouTube.com/watch?v=123")
        #expect(normalized == "youtube.com")
    }

    @Test("rejects invalid domains")
    func rejectsInvalidDomains() {
        #expect(DomainSanitizer.normalized("not_a_domain") == nil)
        #expect(DomainSanitizer.normalized("") == nil)
        #expect(DomainSanitizer.normalized("--bad.com") == nil)
    }

    @Test("normalizes list and removes duplicates")
    func normalizesList() {
        let normalized = DomainSanitizer.normalizeList([
            "https://reddit.com/r/swift",
            "reddit.com",
            "www.apple.com"
        ])

        #expect(normalized == ["reddit.com", "www.apple.com"])
    }
}
