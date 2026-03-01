import Foundation
import Testing
@testable import mControlApp

@Suite("PFRefreshDaemonManager")
struct PFRefreshDaemonManagerTests {
    @Test("launchd plist contains expected label, binary path, and 1m interval")
    func launchdPlistContainsExpectedSettings() {
        let content = PFRefreshDaemonManager.launchDaemonPlistContent()

        #expect(content.contains("<string>com.mcontrol.pfrefresh</string>"))
        #expect(content.contains("<string>/Library/PrivilegedHelperTools/com.mcontrol.pfrefresh</string>"))
        #expect(content.contains("<integer>60</integer>"))
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

    @Test("installationState reports outdated when daemon files do not match expected config")
    func installationStateDetectsOutdatedInstall() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcontrol-daemon-state-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let installedBinaryURL = tempRoot.appendingPathComponent("installed-daemon")
        let bundledBinaryURL = tempRoot.appendingPathComponent("bundled-daemon")
        let plistURL = tempRoot.appendingPathComponent("com.mcontrol.pfrefresh.plist")

        try Data("installed".utf8).write(to: installedBinaryURL)
        try Data("bundled".utf8).write(to: bundledBinaryURL)

        let outdatedPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.mcontrol.pfrefresh</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedBinaryURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StartInterval</key>
            <integer>3600</integer>
        </dict>
        </plist>
        """
        try outdatedPlist.write(to: plistURL, atomically: true, encoding: .utf8)

        let state = PFRefreshDaemonManager.installationState(
            fileManager: fileManager,
            installedBinaryPathOverride: installedBinaryURL.path,
            launchDaemonPlistPathOverride: plistURL.path,
            bundledBinaryURLOverride: bundledBinaryURL
        )

        #expect(state == .installedOutdated)
    }

    @Test("installationState reports current when binary and plist match expected config")
    func installationStateDetectsCurrentInstall() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcontrol-daemon-state-current-tests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let installedBinaryURL = tempRoot.appendingPathComponent("installed-daemon")
        let bundledBinaryURL = tempRoot.appendingPathComponent("bundled-daemon")
        let plistURL = tempRoot.appendingPathComponent("com.mcontrol.pfrefresh.plist")

        let daemonData = Data("same-daemon-binary".utf8)
        try daemonData.write(to: installedBinaryURL)
        try daemonData.write(to: bundledBinaryURL)

        let validPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.mcontrol.pfrefresh</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedBinaryURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StartInterval</key>
            <integer>60</integer>
        </dict>
        </plist>
        """
        try validPlist.write(to: plistURL, atomically: true, encoding: .utf8)

        let state = PFRefreshDaemonManager.installationState(
            fileManager: fileManager,
            installedBinaryPathOverride: installedBinaryURL.path,
            launchDaemonPlistPathOverride: plistURL.path,
            bundledBinaryURLOverride: bundledBinaryURL
        )

        #expect(state == .installedCurrent)
    }
}
