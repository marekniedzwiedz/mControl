import Foundation
import Testing
@testable import mControlApp

@Suite("DigDomainResolver")
struct DigDomainResolverTests {
    @Test("aggregates rotating A answers across repeated dig attempts")
    func aggregatesRotatingAAnswersAcrossRepeatedDigAttempts() {
        let rotating = RotatingARecordsDigStub(
            responses: [
                ["www.zalando-lounge.pl.edgekey.net.", "95.101.116.16"],
                ["e10048238.a.akamaiedge.net.", "95.101.116.21"],
                ["95.101.116.20"],
                ["95.101.116.16"]
            ]
        )

        let resolver = DigDomainResolver(
            digAttemptsPerRecord: 4,
            systemResolve: { _ in ResolvedIPSet(ipv4: [], ipv6: []) },
            digCommand: { domain, recordType in
                rotating.query(domain: domain, recordType: recordType)
            }
        )

        let resolved = resolver.resolveIPAddresses(for: ["https://www.zalando-lounge.pl/event"])

        #expect(Set(["95.101.116.16", "95.101.116.20", "95.101.116.21"]).isSubset(of: resolved.ipv4))
        #expect(resolved.ipv6.isEmpty)
    }

    @Test("merges system resolver and dig outputs while ignoring non-IP dig lines")
    func mergesSystemResolverAndDigOutputs() {
        let resolver = DigDomainResolver(
            digAttemptsPerRecord: 1,
            systemResolve: { host in
                if host.hasPrefix("www.") {
                    return ResolvedIPSet(ipv4: ["203.0.113.10"], ipv6: [])
                }
                return ResolvedIPSet(ipv4: [], ipv6: ["2001:db8::10"])
            },
            digCommand: { _, recordType in
                if recordType == "A" {
                    return ["alias.example.net.", "198.51.100.20"]
                }
                return ["alias.example.net.", "2001:db8::20"]
            }
        )

        let resolved = resolver.resolveIPAddresses(for: ["example.com"])

        #expect(resolved.ipv4 == Set(["198.51.100.20", "203.0.113.10"]))
        #expect(resolved.ipv6 == Set(["2001:db8::10", "2001:db8::20"]))
    }

    @Test("follows CNAME chain from dig results to collect edge IPs")
    func followsCnameChainFromDigResults() {
        let resolver = DigDomainResolver(
            digAttemptsPerRecord: 1,
            systemResolve: { _ in ResolvedIPSet(ipv4: [], ipv6: []) },
            digCommand: { domain, recordType in
                guard recordType == "A" else {
                    return []
                }

                if domain == "www.zalando-lounge.pl" {
                    return ["www.zalando-lounge.pl.edgekey.net."]
                }

                if domain == "www.zalando-lounge.pl.edgekey.net" {
                    return ["e10048238.a.akamaiedge.net."]
                }

                if domain == "e10048238.a.akamaiedge.net" {
                    return ["95.101.116.8", "95.101.116.16", "95.101.116.20"]
                }

                return []
            }
        )

        let resolved = resolver.resolveIPAddresses(for: ["www.zalando-lounge.pl"])

        #expect(Set(["95.101.116.8", "95.101.116.16", "95.101.116.20"]).isSubset(of: resolved.ipv4))
        #expect(resolved.ipv6.isEmpty)
    }

    @Test("merges DoH answers with dig answers for better CDN coverage")
    func mergesDoHAnswersWithDigAnswers() {
        let resolver = DigDomainResolver(
            digAttemptsPerRecord: 1,
            systemResolve: { _ in ResolvedIPSet(ipv4: [], ipv6: []) },
            digCommand: { domain, recordType in
                guard recordType == "A" else {
                    return []
                }
                if domain == "www.zalando-lounge.pl" {
                    return ["e10048238.a.akamaiedge.net.", "95.101.116.8", "95.101.116.16"]
                }
                if domain == "e10048238.a.akamaiedge.net" {
                    return ["95.101.116.8", "95.101.116.16"]
                }
                return []
            },
            doHQuery: { domain, recordType in
                if domain == "www.zalando-lounge.pl", recordType == "A" {
                    return ["95.101.116.11"]
                }
                return []
            }
        )

        let resolved = resolver.resolveIPAddresses(for: ["www.zalando-lounge.pl"])

        #expect(Set(["95.101.116.8", "95.101.116.11", "95.101.116.16"]).isSubset(of: resolved.ipv4))
    }

    @Test("queries DoH for CNAME-chain hosts to widen edge IP coverage")
    func queriesDoHForCnameHosts() {
        var doHQueries: [(String, String)] = []
        let resolver = DigDomainResolver(
            digAttemptsPerRecord: 1,
            systemResolve: { _ in ResolvedIPSet(ipv4: [], ipv6: []) },
            digCommand: { domain, recordType in
                guard recordType == "A" else {
                    return []
                }
                if domain == "www.zalando-lounge.pl" {
                    return ["e10048238.a.akamaiedge.net."]
                }
                return []
            },
            doHQuery: { domain, recordType in
                doHQueries.append((domain, recordType))
                if domain == "e10048238.a.akamaiedge.net", recordType == "A" {
                    return ["95.100.135.209", "95.100.135.233"]
                }
                return []
            }
        )

        let resolved = resolver.resolveIPAddresses(for: ["www.zalando-lounge.pl"])

        #expect(Set(["95.100.135.209", "95.100.135.233"]).isSubset(of: resolved.ipv4))
        #expect(doHQueries.contains { $0.0 == "www.zalando-lounge.pl" && $0.1 == "A" })
        #expect(doHQueries.contains { $0.0 == "e10048238.a.akamaiedge.net" && $0.1 == "A" })
    }

    @Test("derives /24 CIDR entries for high-churn ipv4 pools")
    func derivesCIDRForHighChurnIPv4Pools() {
        let resolver = DigDomainResolver(
            digAttemptsPerRecord: 1,
            systemResolve: { _ in ResolvedIPSet(ipv4: [], ipv6: []) },
            digCommand: { domain, recordType in
                guard recordType == "A", domain == "www.zalando-lounge.pl" else {
                    return []
                }
                return [
                    "2.17.147.131",
                    "2.17.147.152",
                    "2.17.147.176",
                    "2.17.147.202",
                    "18.185.173.97"
                ]
            }
        )

        let resolved = resolver.resolveIPAddresses(for: ["www.zalando-lounge.pl"])
        #expect(resolved.ipv4CIDRs.contains("2.17.147.0/24"))
        #expect(!resolved.ipv4CIDRs.contains("18.185.173.0/24"))
    }
}

private final class RotatingARecordsDigStub {
    private let responses: [[String]]
    private var callCountByDomain: [String: Int] = [:]

    init(responses: [[String]]) {
        self.responses = responses
    }

    func query(domain: String, recordType: String) -> [String] {
        guard recordType == "A", !responses.isEmpty else {
            return []
        }

        let count = callCountByDomain[domain, default: 0]
        callCountByDomain[domain] = count + 1
        let index = min(count, responses.count - 1)
        return responses[index]
    }
}
