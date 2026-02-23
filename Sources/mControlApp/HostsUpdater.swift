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

    var isEmpty: Bool {
        ipv4.isEmpty && ipv6.isEmpty
    }
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

    private let digAttemptsPerRecord: Int
    private let systemResolve: SystemResolveFunction
    private let digCommand: DigCommandFunction

    init(digPath: String = "/usr/bin/dig", digAttemptsPerRecord: Int = 4) {
        self.digAttemptsPerRecord = max(1, digAttemptsPerRecord)
        self.systemResolve = { host in
            DigDomainResolver.resolveUsingGetAddrInfo(host: host)
        }
        self.digCommand = { domain, recordType in
            DigDomainResolver.runDigProcess(digPath: digPath, domain: domain, recordType: recordType)
        }
    }

    init(
        digAttemptsPerRecord: Int = 4,
        systemResolve: @escaping SystemResolveFunction,
        digCommand: @escaping DigCommandFunction
    ) {
        self.digAttemptsPerRecord = max(1, digAttemptsPerRecord)
        self.systemResolve = systemResolve
        self.digCommand = digCommand
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

            for line in runDig(domain: domain, recordType: "A") where isIPv4(line) {
                if line != "0.0.0.0" && line != "127.0.0.1" {
                    ipv4.insert(line)
                }
            }

            for line in runDig(domain: domain, recordType: "AAAA") where isIPv6(line) {
                if line != "::" && line != "::1" {
                    ipv6.insert(line)
                }
            }
        }

        return ResolvedIPSet(ipv4: ipv4, ipv6: ipv6)
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

    private func runDig(domain: String, recordType: String) -> [String] {
        var orderedResults: [String] = []
        var seen = Set<String>()

        for _ in 0 ..< digAttemptsPerRecord {
            for value in digCommand(domain, recordType) where seen.insert(value).inserted {
                orderedResults.append(value)
            }
        }

        return orderedResults
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
}

final class ManagedHostsUpdater: HostsUpdating {
    private let fileManager: FileManager
    private let hostsURL: URL
    private let privilegedRunner: PrivilegedCommandRunning
    private let resolver: DomainIPResolving

    private let pfAnchorName: String
    private let pfAnchorPath: String

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

        let effectiveResolvedIPs: ResolvedIPSet
        if normalizedDomains.isEmpty {
            effectiveResolvedIPs = ResolvedIPSet(ipv4: [], ipv6: [])
        } else if !freshlyResolvedIPs.isEmpty {
            effectiveResolvedIPs = freshlyResolvedIPs
        } else {
            effectiveResolvedIPs = readExistingPFAnchorResolvedIPs()
        }

        let pfAnchorContent = renderPFAnchor(
            ipv4: effectiveResolvedIPs.ipv4,
            ipv6: effectiveResolvedIPs.ipv6
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

    private func renderPFAnchor(ipv4: Set<String>, ipv6: Set<String>) -> String {
        var lines: [String] = ["# mControl generated PF rules"]

        let sortedIPv4 = ipv4.sorted()
        if !sortedIPv4.isEmpty {
            lines.append("table <mcontrol_ipv4> persist { \(sortedIPv4.joined(separator: ", ")) }")
            lines.append("block drop out quick inet to <mcontrol_ipv4>")
        }

        let sortedIPv6 = ipv6.sorted()
        if !sortedIPv6.isEmpty {
            lines.append("table <mcontrol_ipv6> persist { \(sortedIPv6.joined(separator: ", ")) }")
            lines.append("block drop out quick inet6 to <mcontrol_ipv6>")
        }

        if sortedIPv4.isEmpty && sortedIPv6.isEmpty {
            lines.append("# no resolvable addresses at apply time")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func readExistingPFAnchorResolvedIPs() -> ResolvedIPSet {
        guard let existingAnchorContent = try? String(contentsOfFile: pfAnchorPath, encoding: .utf8) else {
            return ResolvedIPSet(ipv4: [], ipv6: [])
        }

        var ipv4 = Set<String>()
        var ipv6 = Set<String>()

        let separators = CharacterSet(charactersIn: "{} ,\n\t\r")
        let tokens = existingAnchorContent
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for token in tokens {
            if isIPv4(token), token != "0.0.0.0", token != "127.0.0.1" {
                ipv4.insert(token)
            } else if isIPv6(token), token != "::", token != "::1" {
                ipv6.insert(token)
            }
        }

        return ResolvedIPSet(ipv4: ipv4, ipv6: ipv6)
    }

    private func isIPv4(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private func isIPv6(_ value: String) -> Bool {
        var addr = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    private func shellQuote(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
