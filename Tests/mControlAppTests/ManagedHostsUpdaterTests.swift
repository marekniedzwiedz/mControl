import BlockingCore
import Foundation
import Testing
@testable import mControlApp

@Suite("ManagedHostsUpdater")
struct ManagedHostsUpdaterTests {
    @MainActor
    @Test("falls back to existing PF anchor IPs when resolver returns empty")
    func fallsBackToExistingPFAnchorIPsWhenResolverReturnsEmpty() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcontrol-updater-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let hostsURL = tempRoot.appendingPathComponent("hosts")
        let pfAnchorPath = tempRoot.appendingPathComponent("pf.anchor").path

        let hostsContent = HostsSectionRenderer.render(
            originalHosts: "127.0.0.1 localhost\n",
            activeDomains: ["x.com"]
        )
        try hostsContent.write(to: hostsURL, atomically: true, encoding: .utf8)

        let existingPFAnchor = """
        # mControl generated PF rules
        table <mcontrol_ipv4> persist { 104.244.42.1, 104.244.42.65 }
        block drop out quick inet to <mcontrol_ipv4>
        """
        try existingPFAnchor.write(toFile: pfAnchorPath, atomically: true, encoding: .utf8)

        let runner = CapturingPrivilegedRunner()
        let updater = ManagedHostsUpdater(
            fileManager: fileManager,
            hostsURL: hostsURL,
            privilegedRunner: runner,
            resolver: EmptyResolver(),
            pfAnchorName: "com.apple/test-mcontrol",
            pfAnchorPath: pfAnchorPath
        )

        try updater.apply(activeDomains: ["x.com"])

        let lastCommand = try #require(runner.lastCommand)
        #expect(lastCommand.contains("mcontrol-pf-"))
        #expect(lastCommand.contains("pfctl -q -a"))
        #expect(lastCommand.contains("pfctl -k 0.0.0.0/0 -k '104.244.42.1'"))
        #expect(!lastCommand.contains("-F all"))

        // Resolver returned empty, so PF update command proves fallback IPs were
        // read from existing anchor and re-applied instead of being dropped.
    }
}

private final class CapturingPrivilegedRunner: PrivilegedCommandRunning {
    private(set) var lastCommand: String?

    @MainActor
    func runShellCommandWithAdminPrivileges(_ command: String) throws {
        lastCommand = command
    }
}

private struct EmptyResolver: DomainIPResolving {
    func resolveIPAddresses(for domains: [String]) -> ResolvedIPSet {
        _ = domains
        return ResolvedIPSet(ipv4: [], ipv6: [])
    }
}
