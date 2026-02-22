import BlockingCore
import Testing

@Suite("HostsSectionRenderer")
struct HostsSectionRendererTests {
    @Test("inserts managed section with ipv4/ipv6 and www aliases")
    func insertsManagedSection() {
        let originalHosts = "127.0.0.1 localhost\n"

        let rendered = HostsSectionRenderer.render(
            originalHosts: originalHosts,
            activeDomains: ["youtube.com", "www.reddit.com"]
        )

        #expect(rendered.contains(HostsSectionRenderer.beginMarker))
        #expect(rendered.contains("0.0.0.0 youtube.com"))
        #expect(rendered.contains(":: youtube.com"))
        #expect(rendered.contains("0.0.0.0 www.youtube.com"))
        #expect(rendered.contains("0.0.0.0 www.reddit.com"))
        #expect(rendered.contains(HostsSectionRenderer.endMarker))
    }

    @Test("removes existing managed section when no domains remain")
    func removesManagedSectionWhenNoDomainsRemain() {
        let input = """
        127.0.0.1 localhost

        # >>> mControl BEGIN
        127.0.0.1 youtube.com
        ::1 youtube.com
        # <<< mControl END
        """

        let rendered = HostsSectionRenderer.render(originalHosts: input, activeDomains: [])

        #expect(!rendered.contains(HostsSectionRenderer.beginMarker))
        #expect(rendered.contains("127.0.0.1 localhost"))
    }

    @Test("replacing managed section is deterministic")
    func replacingSectionIsDeterministic() {
        let input = """
        127.0.0.1 localhost

        # >>> mControl BEGIN
        127.0.0.1 old.example.com
        # <<< mControl END
        """

        let rendered = HostsSectionRenderer.render(
            originalHosts: input,
            activeDomains: ["new.example.com", "new.example.com"]
        )

        #expect(!rendered.contains("old.example.com"))
        #expect(rendered.contains("new.example.com"))

        let firstCount = rendered.components(separatedBy: HostsSectionRenderer.beginMarker).count - 1
        let lastCount = rendered.components(separatedBy: HostsSectionRenderer.endMarker).count - 1
        #expect(firstCount == 1)
        #expect(lastCount == 1)
    }

    @Test("deduplicates overlapping root and www domains")
    func deduplicatesOverlappingDomains() {
        let rendered = HostsSectionRenderer.render(
            originalHosts: "",
            activeDomains: ["interia.pl", "www.interia.pl"]
        )

        let rootIPv4Count = rendered.components(separatedBy: "0.0.0.0 interia.pl").count - 1
        let wwwIPv4Count = rendered.components(separatedBy: "0.0.0.0 www.interia.pl").count - 1
        #expect(rootIPv4Count == 1)
        #expect(wwwIPv4Count == 1)
    }
}
