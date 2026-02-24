import Foundation
import Testing
@testable import mControlApp

@Suite("PFRefreshDaemonManager")
struct PFRefreshDaemonManagerTests {
    @Test("launchd plist contains expected label, binary path, and 1h interval")
    func launchdPlistContainsExpectedSettings() {
        let content = PFRefreshDaemonManager.launchDaemonPlistContent()

        #expect(content.contains("<string>com.mcontrol.pfrefresh</string>"))
        #expect(content.contains("<string>/Library/PrivilegedHelperTools/com.mcontrol.pfrefresh</string>"))
        #expect(content.contains("<integer>3600</integer>"))
    }

    @Test("isInstalled requires both binary and launchd plist")
    func isInstalledRequiresBinaryAndPlist() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcontrol-daemon-manager-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let binaryPath = tempRoot.appendingPathComponent("com.mcontrol.pfrefresh").path
        let plistPath = tempRoot.appendingPathComponent("com.mcontrol.pfrefresh.plist").path

        #expect(
            !PFRefreshDaemonManager.isInstalled(
                fileManager: fileManager,
                installedBinaryPathOverride: binaryPath,
                launchDaemonPlistPathOverride: plistPath
            )
        )

        try Data().write(to: URL(fileURLWithPath: binaryPath))
        #expect(
            !PFRefreshDaemonManager.isInstalled(
                fileManager: fileManager,
                installedBinaryPathOverride: binaryPath,
                launchDaemonPlistPathOverride: plistPath
            )
        )

        try Data().write(to: URL(fileURLWithPath: plistPath))
        #expect(
            PFRefreshDaemonManager.isInstalled(
                fileManager: fileManager,
                installedBinaryPathOverride: binaryPath,
                launchDaemonPlistPathOverride: plistPath
            )
        )
    }
}
