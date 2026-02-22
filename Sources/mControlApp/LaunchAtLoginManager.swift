import Foundation
import ServiceManagement

enum LaunchAtLoginError: LocalizedError {
    case unsupportedSystemVersion
    case executablePathUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedSystemVersion:
            return "Launch at Login requires macOS 13 or newer."
        case .executablePathUnavailable:
            return "Unable to locate the app executable for Launch at Login."
        }
    }
}

enum LaunchAtLoginManager {
    private static let launchAgentLabel = "com.mcontrol.launch-at-login"
    private static let launchAgentPath = "Library/LaunchAgents/\(launchAgentLabel).plist"

    static func isEnabled() -> Bool {
        if #available(macOS 13.0, *), isRunningFromAppBundle {
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval {
                return true
            }
        }

        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *), isRunningFromAppBundle {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }

                if !enabled {
                    try removeLaunchAgentIfExists()
                }
                return
            } catch {
                // Fall back to a user LaunchAgent for unsigned/dev builds
                // where SMAppService may fail with "Invalid argument".
            }
        }

        if enabled {
            try writeLaunchAgent()
        } else {
            try removeLaunchAgentIfExists()
        }
    }

    private static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(launchAgentPath)
    }

    private static func writeLaunchAgent() throws {
        let arguments = try launchArguments()

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private static func removeLaunchAgentIfExists() throws {
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private static func launchArguments() throws -> [String] {
        if isRunningFromAppBundle {
            return ["/usr/bin/open", Bundle.main.bundleURL.path]
        }

        guard let executablePath = Bundle.main.executableURL?.path else {
            throw LaunchAtLoginError.executablePathUnavailable
        }

        return [executablePath]
    }
}
