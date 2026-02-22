import Foundation

public enum HostsSectionRenderer {
    public static let beginMarker = "# >>> mControl BEGIN"
    public static let endMarker = "# <<< mControl END"

    public static func render(originalHosts: String, activeDomains: [String]) -> String {
        let domains = DomainSanitizer.normalizeList(activeDomains)
        let stripped = removingManagedSection(from: originalHosts)

        guard !domains.isEmpty else {
            return stripped
        }

        let section = managedSection(for: domains)

        if stripped.isEmpty {
            return section + "\n"
        }

        var output = stripped
        if !output.hasSuffix("\n") {
            output += "\n"
        }

        output += "\n"
        output += section
        output += "\n"

        return output
    }

    public static func managedSection(for activeDomains: [String]) -> String {
        let domains = DomainSanitizer.normalizeList(activeDomains)
        guard !domains.isEmpty else {
            return ""
        }

        var lines: [String] = [beginMarker]
        var emittedHosts = Set<String>()

        for domain in domains {
            for host in expandedDomains(for: domain) {
                guard !emittedHosts.contains(host) else {
                    continue
                }
                emittedHosts.insert(host)
                lines.append("0.0.0.0 \(host)")
                lines.append(":: \(host)")
            }
        }

        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    public static func removingManagedSection(from hosts: String) -> String {
        let pattern = "(?ms)\\n?# >>> mControl BEGIN.*?# <<< mControl END\\n?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return hosts
        }

        let fullRange = NSRange(hosts.startIndex..<hosts.endIndex, in: hosts)
        var stripped = regex.stringByReplacingMatches(in: hosts, options: [], range: fullRange, withTemplate: "\n")

        while stripped.contains("\n\n\n") {
            stripped = stripped.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        stripped = stripped.trimmingCharacters(in: .newlines)

        if stripped.isEmpty {
            return ""
        }

        return stripped + "\n"
    }

    private static func expandedDomains(for domain: String) -> [String] {
        if domain.hasPrefix("www.") {
            let root = String(domain.dropFirst("www.".count))
            return [domain, root]
        }
        return [domain, "www.\(domain)"]
    }
}
