import Foundation
import Testing
@testable import mControlPFDaemon

@Suite("mControlPFDaemon PF refresh selection")
struct PFRefreshSelectionTests {
    @Test("does not reuse fallback IPs for a different domain signature")
    func doesNotReuseFallbackIPsForDifferentDomainSignature() {
        let existing = PFAnchorSnapshot(
            resolvedIPs: ResolvedIPSet(ipv4: ["104.244.42.1"], ipv6: []),
            domainSignature: "x.com",
            updatedAtEpoch: Int(Date().timeIntervalSince1970)
        )

        let effective = effectiveResolvedIPsForRefresh(
            resolved: ResolvedIPSet(ipv4: [], ipv6: []),
            existingAnchorSnapshot: existing,
            currentDomainSignature: "y.com"
        )

        #expect(effective.isEmpty)
    }

    @Test("reuses fallback IPs for the same domain signature when resolution is empty")
    func reusesFallbackIPsForSameDomainSignature() {
        let existing = PFAnchorSnapshot(
            resolvedIPs: ResolvedIPSet(ipv4: ["104.244.42.1"], ipv6: []),
            domainSignature: "x.com",
            updatedAtEpoch: Int(Date().timeIntervalSince1970)
        )

        let effective = effectiveResolvedIPsForRefresh(
            resolved: ResolvedIPSet(ipv4: [], ipv6: []),
            existingAnchorSnapshot: existing,
            currentDomainSignature: "x.com"
        )

        #expect(effective.ipv4 == Set(["104.244.42.1"]))
    }
}
