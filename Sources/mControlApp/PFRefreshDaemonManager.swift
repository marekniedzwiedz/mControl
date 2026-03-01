import Foundation

enum PFRefreshDaemonError: LocalizedError {
    case bundledBinaryNotFound
    case cannotWriteTemporaryPlist(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledBinaryNotFound:
            return "Bundled PF daemon binary was not found in the app resources."
        case let .cannotWriteTemporaryPlist(message):
            return "Unable to prepare PF daemon launchd plist: \(message)"
        case let .installFailed(message):
            return "PF daemon installation failed: \(message)"
        }
    }
}

enum PFRefreshDaemonManager {
    enum InstallationState: Equatable {
        case notInstalled
        case installedOutdated
        case installedCurrent

        var isInstalled: Bool {
            self != .notInstalled
        }

        var isUpToDate: Bool {
            self == .installedCurrent
        }
    }

    static let launchDaemonLabel = "com.mcontrol.pfrefresh"
    static let installedBinaryPath = "/Library/PrivilegedHelperTools/com.mcontrol.pfrefresh"
    static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.mcontrol.pfrefresh.plist"
    static let refreshIntervalSeconds: Int = 60
    private static let bundledBinaryName = "mControlPFDaemon"

    static func isInstalled(
        fileManager: FileManager = .default,
        installedBinaryPathOverride: String? = nil,
        launchDaemonPlistPathOverride: String? = nil
    ) -> Bool {
        let installedBinaryPath = installedBinaryPathOverride ?? self.installedBinaryPath
        let launchDaemonPlistPath = launchDaemonPlistPathOverride ?? self.launchDaemonPlistPath

        return fileManager.fileExists(atPath: installedBinaryPath) &&
            fileManager.fileExists(atPath: launchDaemonPlistPath)
    }

    static func installationState(
        fileManager: FileManager = .default,
        installedBinaryPathOverride: String? = nil,
        launchDaemonPlistPathOverride: String? = nil,
        bundledBinaryURLOverride: URL? = nil
    ) -> InstallationState {
        let installedBinaryPath = installedBinaryPathOverride ?? self.installedBinaryPath
        let launchDaemonPlistPath = launchDaemonPlistPathOverride ?? self.launchDaemonPlistPath

        let hasBinary = fileManager.fileExists(atPath: installedBinaryPath)
        let hasPlist = fileManager.fileExists(atPath: launchDaemonPlistPath)

        guard hasBinary || hasPlist else {
            return .notInstalled
        }

        guard hasBinary, hasPlist else {
            return .installedOutdated
        }

        guard plistMatchesExpectedConfiguration(
            fileManager: fileManager,
            plistPath: launchDaemonPlistPath,
            installedBinaryPath: installedBinaryPath
        ) else {
            return .installedOutdated
        }

        guard let bundledBinaryURL = bundledBinaryURLOverride ?? bundledBinaryURL(fileManager: fileManager),
              filesMatch(
                  fileManager: fileManager,
                  firstPath: installedBinaryPath,
                  secondPath: bundledBinaryURL.path
              )
        else {
            return .installedOutdated
        }

        return .installedCurrent
    }

    @MainActor
    static func installOrUpdate(
        privilegedRunner: PrivilegedCommandRunning = AppleScriptPrivilegedCommandRunner(),
        fileManager: FileManager = .default
    ) throws {
        guard let bundledBinaryURL = bundledBinaryURL(fileManager: fileManager) else {
            throw PFRefreshDaemonError.bundledBinaryNotFound
        }

        let tempPlistURL = fileManager.temporaryDirectory
            .appendingPathComponent("mcontrol-pfrefresh-\(UUID().uuidString).plist")

        do {
            try launchDaemonPlistContent().write(to: tempPlistURL, atomically: true, encoding: .utf8)
        } catch {
            throw PFRefreshDaemonError.cannotWriteTemporaryPlist(error.localizedDescription)
        }

        defer {
            try? fileManager.removeItem(at: tempPlistURL)
        }

        let commandSegments = [
            "mkdir -p \(shellQuote("/Library/PrivilegedHelperTools"))",
            "mkdir -p \(shellQuote("/Library/LaunchDaemons"))",
            "cp \(shellQuote(bundledBinaryURL.path)) \(shellQuote(installedBinaryPath))",
            "chown root:wheel \(shellQuote(installedBinaryPath))",
            "chmod 755 \(shellQuote(installedBinaryPath))",
            "cp \(shellQuote(tempPlistURL.path)) \(shellQuote(launchDaemonPlistPath))",
            "chown root:wheel \(shellQuote(launchDaemonPlistPath))",
            "chmod 644 \(shellQuote(launchDaemonPlistPath))",
            "launchctl bootout system/\(launchDaemonLabel) >/dev/null 2>&1 || true",
            "launchctl bootstrap system \(shellQuote(launchDaemonPlistPath))",
            "launchctl kickstart -k system/\(launchDaemonLabel)"
        ]

        do {
            try privilegedRunner.runShellCommandWithAdminPrivileges(commandSegments.joined(separator: " && "))
        } catch {
            throw PFRefreshDaemonError.installFailed(error.localizedDescription)
        }
    }

    static func launchDaemonPlistContent() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchDaemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installedBinaryPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StartInterval</key>
            <integer>\(refreshIntervalSeconds)</integer>
            <key>StandardOutPath</key>
            <string>/var/log/\(launchDaemonLabel).log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/\(launchDaemonLabel).log</string>
        </dict>
        </plist>
        """
    }

    private static func bundledBinaryURL(fileManager: FileManager) -> URL? {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(bundledBinaryName),
           fileManager.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        if let executableURL = Bundle.main.executableURL {
            let siblingURL = executableURL.deletingLastPathComponent().appendingPathComponent(bundledBinaryName)
            if fileManager.fileExists(atPath: siblingURL.path) {
                return siblingURL
            }
        }

        let fallbackURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(bundledBinaryName)
        guard fileManager.fileExists(atPath: fallbackURL.path) else {
            return nil
        }
        return fallbackURL
    }

    private static func filesMatch(fileManager: FileManager, firstPath: String, secondPath: String) -> Bool {
        guard let firstData = fileManager.contents(atPath: firstPath),
              let secondData = fileManager.contents(atPath: secondPath)
        else {
            return false
        }
        return firstData == secondData
    }

    private static func plistMatchesExpectedConfiguration(
        fileManager: FileManager,
        plistPath: String,
        installedBinaryPath: String
    ) -> Bool {
        guard let data = fileManager.contents(atPath: plistPath),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any]
        else {
            return false
        }

        guard let label = plist["Label"] as? String, label == launchDaemonLabel else {
            return false
        }

        guard let arguments = plist["ProgramArguments"] as? [String],
              arguments.first == installedBinaryPath
        else {
            return false
        }

        let startInterval: Int? = {
            if let intValue = plist["StartInterval"] as? Int {
                return intValue
            }
            if let numberValue = plist["StartInterval"] as? NSNumber {
                return numberValue.intValue
            }
            return nil
        }()

        return startInterval == refreshIntervalSeconds
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
