import BlockingCore
import Darwin
import Foundation

protocol HostsUpdating {
    @MainActor
    func apply(activeDomains: [String]) throws
}

protocol PrivilegedCommandRunning {
    @MainActor
    func runShellCommandWithAdminPrivileges(_ command: String) throws
}

protocol DomainIPResolving {
    func resolveIPAddresses(for domains: [String]) -> ResolvedIPSet
}

struct ResolvedIPSet {
    var ipv4: Set<String>
    var ipv6: Set<String>
    var ipv4CIDRs: Set<String>
    var ipv6CIDRs: Set<String>

    init(
        ipv4: Set<String>,
        ipv6: Set<String>,
        ipv4CIDRs: Set<String> = [],
        ipv6CIDRs: Set<String> = []
    ) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.ipv4CIDRs = ipv4CIDRs
        self.ipv6CIDRs = ipv6CIDRs
    }

    var isEmpty: Bool {
        ipv4.isEmpty && ipv6.isEmpty && ipv4CIDRs.isEmpty && ipv6CIDRs.isEmpty
    }
}

private struct PFAnchorSnapshot {
    var resolvedIPs: ResolvedIPSet
    var domainSignature: String?
    var updatedAtEpoch: Int?
}

enum HostsUpdaterError: Error, LocalizedError {
    case cannotReadHosts(String)
    case cannotCreateScript
    case privilegedCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .cannotReadHosts(message):
            return "Failed to read /etc/hosts: \(message)"
        case .cannotCreateScript:
            return "Failed to create elevated command script."
        case let .privilegedCommandFailed(message):
            return "Unable to update system blocking: \(message)"
        }
    }
}

final class AppleScriptPrivilegedCommandRunner: PrivilegedCommandRunning {
    @MainActor
    func runShellCommandWithAdminPrivileges(_ command: String) throws {
        let source = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw HostsUpdaterError.cannotCreateScript
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown osascript error"
            throw HostsUpdaterError.privilegedCommandFailed(message)
        }
    }

    private func appleScriptStringLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

final class DigDomainResolver: DomainIPResolving {
    typealias SystemResolveFunction = (String) -> ResolvedIPSet
    typealias DigCommandFunction = (String, String) -> [String]
    typealias DoHQueryFunction = (String, String) -> [String]

    private let digAttemptsPerRecord: Int
    private let systemResolve: SystemResolveFunction
    private let digCommand: DigCommandFunction
    private let doHQuery: DoHQueryFunction
    private let maxDigHostExpansions: Int = 24
    private static let publicDNSResolvers: [String] = [
        "8.8.8.8",
        "1.1.1.1",
        "9.9.9.9",
        "208.67.222.222"
    ]
    private static let aggressiveDigAttemptsPerRecord = 12
    private static let aggressiveResolverRounds = 4
    private static let aggressiveDoHAttemptsPerRecord = 3

    init(digPath: String = "/usr/bin/dig", digAttemptsPerRecord: Int = 4) {
        self.digAttemptsPerRecord = max(1, digAttemptsPerRecord)
        self.systemResolve = { host in
            DigDomainResolver.resolveUsingGetAddrInfo(host: host)
        }
        self.digCommand = { domain, recordType in
            DigDomainResolver.runDigProcess(digPath: digPath, domain: domain, recordType: recordType)
        }
        self.doHQuery = { domain, recordType in
            DigDomainResolver.runDoHQueries(domain: domain, recordType: recordType)
        }
    }

    init(
        digAttemptsPerRecord: Int = 4,
        systemResolve: @escaping SystemResolveFunction,
        digCommand: @escaping DigCommandFunction,
        doHQuery: @escaping DoHQueryFunction = { _, _ in [] }
    ) {
        self.digAttemptsPerRecord = max(1, digAttemptsPerRecord)
        self.systemResolve = systemResolve
        self.digCommand = digCommand
        self.doHQuery = doHQuery
    }

    func resolveIPAddresses(for domains: [String]) -> ResolvedIPSet {
        let normalized = DomainSanitizer.normalizeList(domains)
        let expanded = expandedDomains(from: normalized)

        var ipv4 = Set<String>()
        var ipv6 = Set<String>()

        for domain in expanded {
            let systemResolved = systemResolve(domain)
            for address in systemResolved.ipv4 where address != "0.0.0.0" && address != "127.0.0.1" {
                ipv4.insert(address)
            }
            for address in systemResolved.ipv6 where address != "::" && address != "::1" {
                ipv6.insert(address)
            }

            for address in resolveDigIPs(domain: domain, recordType: "A") {
                if address != "0.0.0.0" && address != "127.0.0.1" {
                    ipv4.insert(address)
                }
            }

            for address in resolveDigIPs(domain: domain, recordType: "AAAA") {
                if address != "::" && address != "::1" {
                    ipv6.insert(address)
                }
            }
        }

        return ResolvedIPSet(
            ipv4: ipv4,
            ipv6: ipv6,
            ipv4CIDRs: deriveHighChurnIPv4Networks(from: ipv4)
        )
    }

    private static func resolveUsingGetAddrInfo(host: String) -> ResolvedIPSet {
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &infoPointer)
        guard status == 0, let infoPointer else {
            return ResolvedIPSet(ipv4: [], ipv6: [])
        }
        defer { freeaddrinfo(infoPointer) }

        var ipv4 = Set<String>()
        var ipv6 = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = infoPointer

        while let node = current {
            let family = node.pointee.ai_family
            if family == AF_INET, let rawAddress = node.pointee.ai_addr {
                var address = rawAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    ipv4.insert(value)
                }
            } else if family == AF_INET6, let rawAddress = node.pointee.ai_addr {
                var address = rawAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    ipv6.insert(value)
                }
            }

            current = node.pointee.ai_next
        }

        return ResolvedIPSet(ipv4: ipv4, ipv6: ipv6)
    }

    private static func runDigProcess(digPath: String, domain: String, recordType: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: digPath)
        process.arguments = ["+time=1", "+tries=1", "+short", domain, recordType]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let string = String(data: data, encoding: .utf8) else {
            return []
        }

        return string
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func runDigWithResolver(
        digPath: String,
        resolver: String,
        domain: String,
        recordType: String
    ) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: digPath)
        process.arguments = ["+time=1", "+tries=1", "+short", "@\(resolver)", domain, recordType]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let string = String(data: data, encoding: .utf8) else {
            return []
        }

        return string
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func runDoHQueries(domain: String, recordType: String) -> [String] {
        guard let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }

        let googleURLs = googleDoHURLs(
            encodedDomain: encodedDomain,
            recordType: recordType,
            aggressiveSampling: shouldUseAggressiveDoHSampling(host: domain)
        )
        let cloudflareURL = "https://cloudflare-dns.com/dns-query?name=\(encodedDomain)&type=\(recordType)"

        var responses: [String] = []
        for googleURL in googleURLs {
            responses.append(contentsOf: runDoHProcess(urlString: googleURL, headers: []))
        }
        responses.append(contentsOf: runDoHProcess(urlString: cloudflareURL, headers: ["accept: application/dns-json"]))

        var orderedResults: [String] = []
        var seen = Set<String>()
        for value in responses where seen.insert(value).inserted {
            orderedResults.append(value)
        }
        return orderedResults
    }

    private static func googleDoHURLs(
        encodedDomain: String,
        recordType: String,
        aggressiveSampling: Bool
    ) -> [String] {
        let baseURL = "https://dns.google/resolve?name=\(encodedDomain)&type=\(recordType)"
        guard aggressiveSampling else {
            return [baseURL]
        }

        let ecsSubnets = [
            "0.0.0.0/0",
            "89.64.0.0/16",
            "95.100.0.0/16",
            "23.0.0.0/8",
            "2.16.0.0/13"
        ]

        var urls = [baseURL]
        for subnet in ecsSubnets {
            urls.append("\(baseURL)&edns_client_subnet=\(subnet)")
        }
        return urls
    }

    private static func shouldUseAggressiveDoHSampling(host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return normalizedHost.contains("akamaiedge.net")
            || normalizedHost.contains("edgekey.net")
    }

    private static func runDoHProcess(urlString: String, headers: [String]) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

        var arguments = ["-m", "2", "-sS"]
        for header in headers {
            arguments.append(contentsOf: ["-H", header])
        }
        arguments.append(urlString)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answerArray = jsonObject["Answer"] as? [[String: Any]]
        else {
            return []
        }

        return answerArray.compactMap { entry in
            guard let value = entry["data"] as? String else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func runDig(domain: String, recordType: String) -> [String] {
        var orderedResults: [String] = []
        var seen = Set<String>()
        let attempts = digAttempts(for: domain, recordType: recordType)

        for _ in 0 ..< attempts {
            for value in digCommand(domain, recordType) where seen.insert(value).inserted {
                orderedResults.append(value)
            }
        }

        return orderedResults
    }

    private func runAggressiveResolverDig(domain: String, recordType: String) -> [String] {
        guard recordType == "A" || recordType == "AAAA" else {
            return []
        }
        guard Self.shouldUseAggressiveDoHSampling(host: domain) else {
            return []
        }

        var orderedResults: [String] = []
        var seen = Set<String>()

        for _ in 0 ..< Self.aggressiveResolverRounds {
            for resolver in Self.publicDNSResolvers {
                let values = Self.runDigWithResolver(
                    digPath: "/usr/bin/dig",
                    resolver: resolver,
                    domain: domain,
                    recordType: recordType
                )
                for value in values where seen.insert(value).inserted {
                    orderedResults.append(value)
                }
            }
        }

        return orderedResults
    }

    private func runDoH(domain: String, recordType: String) -> [String] {
        var orderedResults: [String] = []
        var seen = Set<String>()
        let attempts = doHAttempts(for: domain, recordType: recordType)

        for _ in 0 ..< attempts {
            for value in doHQuery(domain, recordType) where seen.insert(value).inserted {
                orderedResults.append(value)
            }
        }

        return orderedResults
    }

    private func resolveDigIPs(domain: String, recordType: String) -> [String] {
        var queue: [String] = [domain]
        var seenHosts = Set<String>()
        if let normalized = DomainSanitizer.normalized(domain) {
            seenHosts.insert(normalized)
        } else {
            seenHosts.insert(domain.lowercased())
        }

        var orderedIPResults: [String] = []
        var seenIPs = Set<String>()

        while !queue.isEmpty, seenHosts.count <= maxDigHostExpansions {
            let current = queue.removeFirst()
            var responses = runDig(domain: current, recordType: recordType)
            responses.append(contentsOf: runAggressiveResolverDig(domain: current, recordType: recordType))
            if recordType == "A" || recordType == "AAAA" {
                responses.append(contentsOf: runDoH(domain: current, recordType: recordType))
            }

            var seenResponses = Set<String>()
            let mergedResponses = responses.filter { seenResponses.insert($0).inserted }

            for value in mergedResponses {
                if recordType == "A", isIPv4(value) {
                    if seenIPs.insert(value).inserted {
                        orderedIPResults.append(value)
                    }
                    continue
                }

                if recordType == "AAAA", isIPv6(value) {
                    if seenIPs.insert(value).inserted {
                        orderedIPResults.append(value)
                    }
                    continue
                }

                guard let cname = DomainSanitizer.normalized(value),
                      !seenHosts.contains(cname),
                      seenHosts.count < maxDigHostExpansions
                else {
                    continue
                }

                seenHosts.insert(cname)
                queue.append(cname)
            }
        }

        return orderedIPResults
    }

    private func digAttempts(for domain: String, recordType: String) -> Int {
        guard recordType == "A" || recordType == "AAAA",
              Self.shouldUseAggressiveDoHSampling(host: domain)
        else {
            return digAttemptsPerRecord
        }
        return max(digAttemptsPerRecord, Self.aggressiveDigAttemptsPerRecord)
    }

    private func doHAttempts(for domain: String, recordType: String) -> Int {
        guard recordType == "A" || recordType == "AAAA",
              Self.shouldUseAggressiveDoHSampling(host: domain)
        else {
            return 1
        }
        return Self.aggressiveDoHAttemptsPerRecord
    }

    private func expandedDomains(from domains: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func appendUnique(_ value: String) {
            guard !seen.contains(value) else {
                return
            }
            seen.insert(value)
            result.append(value)
        }

        for domain in domains {
            if domain.hasPrefix("www.") {
                appendUnique(domain)
                appendUnique(String(domain.dropFirst("www.".count)))
            } else {
                appendUnique(domain)
                appendUnique("www.\(domain)")
            }
        }

        return result
    }

    private func isIPv4(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private func isIPv6(_ value: String) -> Bool {
        var addr = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    private func deriveHighChurnIPv4Networks(from ipv4: Set<String>) -> Set<String> {
        var prefixCounts: [String: Int] = [:]

        for address in ipv4 {
            guard let prefix = ipv4Prefix24(address) else {
                continue
            }
            prefixCounts[prefix, default: 0] += 1
        }

        return Set(
            prefixCounts.compactMap { prefix, count in
                guard count >= 4 else {
                    return nil
                }
                return "\(prefix).0/24"
            }
        )
    }

    private func ipv4Prefix24(_ address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else {
            return nil
        }

        var octets: [Int] = []
        octets.reserveCapacity(4)

        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255 else {
                return nil
            }
            octets.append(value)
        }

        return "\(octets[0]).\(octets[1]).\(octets[2])"
    }
}

final class ManagedHostsUpdater: HostsUpdating {
    private let fileManager: FileManager
    private let hostsURL: URL
    private let privilegedRunner: PrivilegedCommandRunning
    private let resolver: DomainIPResolving

    private let pfAnchorName: String
    private let pfAnchorPath: String
    private let rollingUnionMaxEntriesPerFamily: Int = 4096
    private let rollingUnionMaxAgeSeconds: Int = 7 * 24 * 60 * 60

    init(
        fileManager: FileManager = .default,
        hostsURL: URL = URL(fileURLWithPath: "/etc/hosts"),
        privilegedRunner: PrivilegedCommandRunning = AppleScriptPrivilegedCommandRunner(),
        resolver: DomainIPResolving = DigDomainResolver(),
        pfAnchorName: String = "com.apple/mcontrol",
        pfAnchorPath: String = "/etc/pf.anchors/com.apple.mcontrol"
    ) {
        self.fileManager = fileManager
        self.hostsURL = hostsURL
        self.privilegedRunner = privilegedRunner
        self.resolver = resolver
        self.pfAnchorName = pfAnchorName
        self.pfAnchorPath = pfAnchorPath
    }

    @MainActor
    func apply(activeDomains: [String]) throws {
        let normalizedDomains = DomainSanitizer.normalizeList(activeDomains)
        let currentDomainSignature = domainSignature(for: normalizedDomains)

        let originalHosts: String
        do {
            originalHosts = try String(contentsOf: hostsURL, encoding: .utf8)
        } catch {
            throw HostsUpdaterError.cannotReadHosts(error.localizedDescription)
        }

        let updatedHosts = HostsSectionRenderer.render(
            originalHosts: originalHosts,
            activeDomains: normalizedDomains
        )
        let hostsNeedsUpdate = updatedHosts != originalHosts

        let freshlyResolvedIPs = normalizedDomains.isEmpty
            ? ResolvedIPSet(ipv4: [], ipv6: [])
            : resolver.resolveIPAddresses(for: normalizedDomains)

        let existingAnchorSnapshot = readExistingPFAnchorSnapshot()
        let effectiveResolvedIPs: ResolvedIPSet
        if normalizedDomains.isEmpty {
            effectiveResolvedIPs = ResolvedIPSet(ipv4: [], ipv6: [], ipv4CIDRs: [], ipv6CIDRs: [])
        } else if !freshlyResolvedIPs.isEmpty,
                  existingAnchorSnapshot.domainSignature == currentDomainSignature,
                  isSnapshotFresh(existingAnchorSnapshot) {
            effectiveResolvedIPs = ResolvedIPSet(
                ipv4: mergeEntries(
                    newest: freshlyResolvedIPs.ipv4,
                    previous: existingAnchorSnapshot.resolvedIPs.ipv4
                ),
                ipv6: mergeEntries(
                    newest: freshlyResolvedIPs.ipv6,
                    previous: existingAnchorSnapshot.resolvedIPs.ipv6
                ),
                ipv4CIDRs: mergeEntries(
                    newest: freshlyResolvedIPs.ipv4CIDRs,
                    previous: existingAnchorSnapshot.resolvedIPs.ipv4CIDRs
                ),
                ipv6CIDRs: mergeEntries(
                    newest: freshlyResolvedIPs.ipv6CIDRs,
                    previous: existingAnchorSnapshot.resolvedIPs.ipv6CIDRs
                )
            )
        } else if !freshlyResolvedIPs.isEmpty {
            effectiveResolvedIPs = freshlyResolvedIPs
        } else {
            effectiveResolvedIPs = existingAnchorSnapshot.resolvedIPs
        }

        let pfAnchorContent = renderPFAnchor(
            ipv4: effectiveResolvedIPs.ipv4,
            ipv6: effectiveResolvedIPs.ipv6,
            ipv4CIDRs: effectiveResolvedIPs.ipv4CIDRs,
            ipv6CIDRs: effectiveResolvedIPs.ipv6CIDRs,
            domainSignature: normalizedDomains.isEmpty ? nil : currentDomainSignature,
            updatedAtEpoch: normalizedDomains.isEmpty ? nil : Int(Date().timeIntervalSince1970)
        )

        var temporaryURLs: [URL] = []
        defer {
            for url in temporaryURLs {
                try? fileManager.removeItem(at: url)
            }
        }

        var commandSegments: [String] = []

        if hostsNeedsUpdate {
            let tempHostsURL = fileManager.temporaryDirectory
                .appendingPathComponent("mcontrol-hosts-\(UUID().uuidString).tmp")
            try updatedHosts.write(to: tempHostsURL, atomically: true, encoding: .utf8)
            temporaryURLs.append(tempHostsURL)

            commandSegments.append(
                "cp \(shellQuote(tempHostsURL.path)) \(shellQuote(hostsURL.path)) && dscacheutil -flushcache && killall -HUP mDNSResponder"
            )
        }

        if normalizedDomains.isEmpty {
            let tempPFURL = fileManager.temporaryDirectory
                .appendingPathComponent("mcontrol-pf-\(UUID().uuidString).conf")
            try pfAnchorContent.write(to: tempPFURL, atomically: true, encoding: .utf8)
            temporaryURLs.append(tempPFURL)

            commandSegments.append(
                "cp \(shellQuote(tempPFURL.path)) \(shellQuote(pfAnchorPath)) && (pfctl -a \(shellQuote(pfAnchorName)) -F all || true)"
            )
        } else if !effectiveResolvedIPs.isEmpty {
            let tempPFURL = fileManager.temporaryDirectory
                .appendingPathComponent("mcontrol-pf-\(UUID().uuidString).conf")
            try pfAnchorContent.write(to: tempPFURL, atomically: true, encoding: .utf8)
            temporaryURLs.append(tempPFURL)

            commandSegments.append(
                "cp \(shellQuote(tempPFURL.path)) \(shellQuote(pfAnchorPath)) && pfctl -q -a \(shellQuote(pfAnchorName)) -f \(shellQuote(pfAnchorPath)) && (pfctl -s info | grep -q 'Status: Enabled' || pfctl -E)"
            )

            let killStateCommands = renderPFStateKillCommands(
                ipv4: effectiveResolvedIPs.ipv4,
                ipv6: effectiveResolvedIPs.ipv6
            )
            if !killStateCommands.isEmpty {
                commandSegments.append(killStateCommands.joined(separator: " && "))
            }
        }

        if !commandSegments.isEmpty {
            let combinedCommand = commandSegments.joined(separator: " && ")
            try privilegedRunner.runShellCommandWithAdminPrivileges(combinedCommand)
        }

        let reloadedHosts = try String(contentsOf: hostsURL, encoding: .utf8)
        let hasManagedHostsBlock = reloadedHosts.contains(HostsSectionRenderer.beginMarker)

        if normalizedDomains.isEmpty && hasManagedHostsBlock {
            throw HostsUpdaterError.privilegedCommandFailed("mControl hosts block is still present after cleanup.")
        }
        if !normalizedDomains.isEmpty && !hasManagedHostsBlock {
            throw HostsUpdaterError.privilegedCommandFailed("mControl hosts block was not written to /etc/hosts.")
        }
    }

    private func renderPFAnchor(
        ipv4: Set<String>,
        ipv6: Set<String>,
        ipv4CIDRs: Set<String>,
        ipv6CIDRs: Set<String>,
        domainSignature: String?,
        updatedAtEpoch: Int?
    ) -> String {
        var lines: [String] = ["# mControl generated PF rules"]
        if let domainSignature, !domainSignature.isEmpty {
            lines.append("# mControl domains: \(domainSignature)")
        }
        if let updatedAtEpoch {
            lines.append("# mControl updatedAt: \(updatedAtEpoch)")
        }

        let sortedIPv4Entries = ipv4.union(ipv4CIDRs).sorted()
        if !sortedIPv4Entries.isEmpty {
            lines.append("table <mcontrol_ipv4> persist { \(sortedIPv4Entries.joined(separator: ", ")) }")
            lines.append("block drop out quick inet to <mcontrol_ipv4>")
        }

        let sortedIPv6Entries = ipv6.union(ipv6CIDRs).sorted()
        if !sortedIPv6Entries.isEmpty {
            lines.append("table <mcontrol_ipv6> persist { \(sortedIPv6Entries.joined(separator: ", ")) }")
            lines.append("block drop out quick inet6 to <mcontrol_ipv6>")
        }

        if sortedIPv4Entries.isEmpty && sortedIPv6Entries.isEmpty {
            lines.append("# no resolvable addresses at apply time")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func renderPFStateKillCommands(ipv4: Set<String>, ipv6: Set<String>) -> [String] {
        var commands: [String] = []

        for address in ipv4.sorted() {
            commands.append("pfctl -k 0.0.0.0/0 -k \(shellQuote(address)) >/dev/null 2>&1 || true")
        }

        for address in ipv6.sorted() {
            commands.append("pfctl -k ::/0 -k \(shellQuote(address)) >/dev/null 2>&1 || true")
        }

        return commands
    }

    private func readExistingPFAnchorSnapshot() -> PFAnchorSnapshot {
        guard let existingAnchorContent = try? String(contentsOfFile: pfAnchorPath, encoding: .utf8) else {
            return PFAnchorSnapshot(
                resolvedIPs: ResolvedIPSet(ipv4: [], ipv6: []),
                domainSignature: nil,
                updatedAtEpoch: nil
            )
        }

        var ipv4 = Set<String>()
        var ipv6 = Set<String>()
        var ipv4CIDRs = Set<String>()
        var ipv6CIDRs = Set<String>()
        var domainSignature: String?
        var updatedAtEpoch: Int?

        for line in existingAnchorContent.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "# mControl domains: "
            if trimmed.hasPrefix(prefix) {
                domainSignature = String(trimmed.dropFirst(prefix.count))
            }

            let updatedPrefix = "# mControl updatedAt: "
            if trimmed.hasPrefix(updatedPrefix) {
                let raw = String(trimmed.dropFirst(updatedPrefix.count))
                updatedAtEpoch = Int(raw)
            }
        }

        let separators = CharacterSet(charactersIn: "{} ,\n\t\r")
        let tokens = existingAnchorContent
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for token in tokens {
            if isIPv4(token), token != "0.0.0.0", token != "127.0.0.1" {
                ipv4.insert(token)
            } else if isIPv4CIDR(token) {
                ipv4CIDRs.insert(token)
            } else if isIPv6(token), token != "::", token != "::1" {
                ipv6.insert(token)
            } else if isIPv6CIDR(token) {
                ipv6CIDRs.insert(token)
            }
        }

        return PFAnchorSnapshot(
            resolvedIPs: ResolvedIPSet(
                ipv4: ipv4,
                ipv6: ipv6,
                ipv4CIDRs: ipv4CIDRs,
                ipv6CIDRs: ipv6CIDRs
            ),
            domainSignature: domainSignature,
            updatedAtEpoch: updatedAtEpoch
        )
    }

    private func isIPv4(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private func isIPv6(_ value: String) -> Bool {
        var addr = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    private func isIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 32
        else {
            return false
        }
        return isIPv4(String(parts[0]))
    }

    private func isIPv6CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 128
        else {
            return false
        }
        return isIPv6(String(parts[0]))
    }

    private func shellQuote(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func domainSignature(for domains: [String]) -> String {
        DomainSanitizer.normalizeList(domains)
            .sorted()
            .joined(separator: ",")
    }

    private func isSnapshotFresh(_ snapshot: PFAnchorSnapshot) -> Bool {
        guard let updatedAtEpoch = snapshot.updatedAtEpoch else {
            return true
        }
        let nowEpoch = Int(Date().timeIntervalSince1970)
        return nowEpoch - updatedAtEpoch <= rollingUnionMaxAgeSeconds
    }

    private func mergeEntries(newest: Set<String>, previous: Set<String>) -> Set<String> {
        if newest.count >= rollingUnionMaxEntriesPerFamily {
            return Set(newest.sorted().prefix(rollingUnionMaxEntriesPerFamily))
        }

        var ordered = newest.sorted()
        let newestSet = Set(newest)
        let missingPrevious = previous.sorted().filter { !newestSet.contains($0) }
        for value in missingPrevious {
            if ordered.count >= rollingUnionMaxEntriesPerFamily {
                break
            }
            ordered.append(value)
        }
        return Set(ordered)
    }
}
