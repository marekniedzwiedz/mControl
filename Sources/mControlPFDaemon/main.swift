import BlockingCore
import Darwin
import Foundation

private struct ResolvedIPSet {
    var ipv4: Set<String>
    var ipv6: Set<String>

    var isEmpty: Bool {
        ipv4.isEmpty && ipv6.isEmpty
    }
}

private enum DaemonError: Error, LocalizedError {
    case cannotReadHosts(String)
    case cannotWritePFAnchor(String)
    case commandFailed(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .cannotReadHosts(message):
            return "Unable to read /etc/hosts: \(message)"
        case let .cannotWritePFAnchor(message):
            return "Unable to write PF anchor: \(message)"
        case let .commandFailed(command, message):
            return "Command failed (\(command)): \(message)"
        }
    }
}

private enum Constants {
    static let hostsPath = "/etc/hosts"
    static let pfAnchorName = "com.apple/mcontrol"
    static let pfAnchorPath = "/etc/pf.anchors/com.apple.mcontrol"
    static let digPath = "/usr/bin/dig"
}

private final class DigDomainResolver {
    private let digAttemptsPerRecord: Int
    private let maxDigHostExpansions: Int
    private let doHTimeoutSeconds: Int
    private let doHAttemptsPerRecord: Int

    init(
        digAttemptsPerRecord: Int = 4,
        maxDigHostExpansions: Int = 16,
        doHTimeoutSeconds: Int = 2,
        doHAttemptsPerRecord: Int = 2
    ) {
        self.digAttemptsPerRecord = max(1, digAttemptsPerRecord)
        self.maxDigHostExpansions = max(1, maxDigHostExpansions)
        self.doHTimeoutSeconds = max(1, doHTimeoutSeconds)
        self.doHAttemptsPerRecord = max(1, doHAttemptsPerRecord)
    }

    func resolveIPAddresses(for domains: [String]) -> ResolvedIPSet {
        let normalized = DomainSanitizer.normalizeList(domains)
        let expanded = expandedDomains(from: normalized)

        var ipv4 = Set<String>()
        var ipv6 = Set<String>()

        for domain in expanded {
            let systemResolved = resolveUsingGetAddrInfo(host: domain)
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

        return ResolvedIPSet(ipv4: ipv4, ipv6: ipv6)
    }

    private func resolveUsingGetAddrInfo(host: String) -> ResolvedIPSet {
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

    private func runDig(domain: String, recordType: String) -> [String] {
        var orderedResults: [String] = []
        var seen = Set<String>()

        for _ in 0 ..< digAttemptsPerRecord {
            for value in runDigProcess(domain: domain, recordType: recordType) where seen.insert(value).inserted {
                orderedResults.append(value)
            }
        }

        return orderedResults
    }

    private func runDoH(domain: String, recordType: String) -> [String] {
        guard let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }

        let googleURL = "https://dns.google/resolve?name=\(encodedDomain)&type=\(recordType)"
        let cloudflareURL = "https://cloudflare-dns.com/dns-query?name=\(encodedDomain)&type=\(recordType)"

        var responses: [String] = []
        for _ in 0 ..< doHAttemptsPerRecord {
            responses.append(contentsOf: runDoHProcess(urlString: googleURL, headers: []))
            responses.append(contentsOf: runDoHProcess(urlString: cloudflareURL, headers: ["accept: application/dns-json"]))
        }

        var orderedResults: [String] = []
        var seen = Set<String>()
        for value in responses where seen.insert(value).inserted {
            orderedResults.append(value)
        }
        return orderedResults
    }

    private func runDigProcess(domain: String, recordType: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Constants.digPath)
        process.arguments = ["+time=1", "+tries=1", "+short", domain, recordType]

        let stdout = Pipe()
        process.standardOutput = stdout
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

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func runDoHProcess(urlString: String, headers: [String]) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

        var arguments = ["-m", "\(doHTimeoutSeconds)", "-sS"]
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

    private func resolveDigIPs(domain: String, recordType: String) -> [String] {
        var queue: [String] = [domain]
        var seenHosts = Set<String>()

        if let normalized = DomainSanitizer.normalized(domain) {
            seenHosts.insert(normalized)
        } else {
            seenHosts.insert(domain.lowercased())
        }

        var orderedIPs: [String] = []
        var seenIPs = Set<String>()

        while !queue.isEmpty, seenHosts.count <= maxDigHostExpansions {
            let current = queue.removeFirst()
            var responses = runDig(domain: current, recordType: recordType)
            if recordType == "A", current == domain {
                responses.append(contentsOf: runDoH(domain: current, recordType: recordType))
            }

            var seenResponses = Set<String>()
            let mergedResponses = responses.filter { seenResponses.insert($0).inserted }

            for value in mergedResponses {
                if recordType == "A", isIPv4(value) {
                    if seenIPs.insert(value).inserted {
                        orderedIPs.append(value)
                    }
                    continue
                }

                if recordType == "AAAA", isIPv6(value) {
                    if seenIPs.insert(value).inserted {
                        orderedIPs.append(value)
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

        return orderedIPs
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

private func loadManagedDomainsFromHosts() throws -> [String] {
    let hostsContent: String
    do {
        hostsContent = try String(contentsOfFile: Constants.hostsPath, encoding: .utf8)
    } catch {
        throw DaemonError.cannotReadHosts(error.localizedDescription)
    }

    guard let beginRange = hostsContent.range(of: HostsSectionRenderer.beginMarker),
          let endRange = hostsContent.range(of: HostsSectionRenderer.endMarker, range: beginRange.upperBound..<hostsContent.endIndex)
    else {
        return []
    }

    let managedSection = hostsContent[beginRange.upperBound..<endRange.lowerBound]
    var domains: [String] = []

    for line in managedSection.split(whereSeparator: \.isNewline) {
        let rawLine = String(line)
        let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? rawLine
        let tokens = withoutComment
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard tokens.count >= 2 else {
            continue
        }
        guard tokens[0] == "0.0.0.0" || tokens[0] == "::" else {
            continue
        }
        domains.append(tokens[1])
    }

    return DomainSanitizer.normalizeList(domains)
}

private func readExistingPFAnchorResolvedIPs() -> ResolvedIPSet {
    guard let existingAnchorContent = try? String(contentsOfFile: Constants.pfAnchorPath, encoding: .utf8) else {
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

private func writeAnchorAtomically(_ content: String) throws {
    let fileManager = FileManager.default
    let tempURL = fileManager.temporaryDirectory.appendingPathComponent("mcontrol-daemon-\(UUID().uuidString).tmp")

    do {
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
    } catch {
        throw DaemonError.cannotWritePFAnchor(error.localizedDescription)
    }

    defer {
        try? fileManager.removeItem(at: tempURL)
    }

    do {
        if fileManager.fileExists(atPath: Constants.pfAnchorPath) {
            try fileManager.removeItem(atPath: Constants.pfAnchorPath)
        }
        try fileManager.moveItem(at: tempURL, to: URL(fileURLWithPath: Constants.pfAnchorPath))
    } catch {
        throw DaemonError.cannotWritePFAnchor(error.localizedDescription)
    }
}

@discardableResult
private func runCommand(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

    let stdoutText = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus != 0 && !allowFailure {
        let message = stderrText.isEmpty ? stdoutText : stderrText
        throw DaemonError.commandFailed(
            command: "\(executable) \(arguments.joined(separator: " "))",
            message: message.isEmpty ? "exit code \(process.terminationStatus)" : message
        )
    }

    if !stderrText.isEmpty {
        return stderrText
    }

    return stdoutText
}

private func isIPv4(_ value: String) -> Bool {
    var addr = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &addr) } == 1
}

private func isIPv6(_ value: String) -> Bool {
    var addr = in6_addr()
    return value.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
}

private func runDaemonRefresh() throws {
    let domains = try loadManagedDomainsFromHosts()

    if domains.isEmpty {
        try writeAnchorAtomically(renderPFAnchor(ipv4: [], ipv6: []))
        _ = try runCommand("/sbin/pfctl", ["-a", Constants.pfAnchorName, "-F", "all"], allowFailure: true)
        print("mControlPFDaemon: no managed domains, PF anchor flushed")
        return
    }

    let resolver = DigDomainResolver(digAttemptsPerRecord: 4)
    let resolved = resolver.resolveIPAddresses(for: domains)
    let effective = resolved.isEmpty ? readExistingPFAnchorResolvedIPs() : resolved

    guard !effective.isEmpty else {
        print("mControlPFDaemon: no resolved IPs and no existing PF fallback, keeping current PF rules")
        return
    }

    let anchorContent = renderPFAnchor(ipv4: effective.ipv4, ipv6: effective.ipv6)
    try writeAnchorAtomically(anchorContent)
    _ = try runCommand("/sbin/pfctl", ["-q", "-a", Constants.pfAnchorName, "-f", Constants.pfAnchorPath])
    _ = try runCommand(
        "/bin/sh",
        ["-c", "/sbin/pfctl -s info | /usr/bin/grep -q 'Status: Enabled' || /sbin/pfctl -E"],
        allowFailure: true
    )
    try killPFStates(ipv4: effective.ipv4, ipv6: effective.ipv6)

    print("mControlPFDaemon: refreshed PF entries for \(domains.count) domain(s), ipv4=\(effective.ipv4.count), ipv6=\(effective.ipv6.count)")
}

private func killPFStates(ipv4: Set<String>, ipv6: Set<String>) throws {
    for address in ipv4.sorted() {
        _ = try runCommand("/sbin/pfctl", ["-k", "0.0.0.0/0", "-k", address], allowFailure: true)
    }

    for address in ipv6.sorted() {
        _ = try runCommand("/sbin/pfctl", ["-k", "::/0", "-k", address], allowFailure: true)
    }
}

do {
    try runDaemonRefresh()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    fputs("mControlPFDaemon error: \(message)\n", stderr)
    exit(EXIT_FAILURE)
}
