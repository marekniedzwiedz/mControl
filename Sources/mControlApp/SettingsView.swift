import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @AppStorage("confirmQuitEnabled") private var confirmQuitEnabled: Bool = true
    @AppStorage("defaultCustomDurationMinutes") private var defaultCustomDurationMinutes: Int = 60

    @State private var launchAtLoginEnabled: Bool = LaunchAtLoginManager.isEnabled()
    @State private var launchAtLoginErrorMessage: String?
    @State private var daemonInstallationState: PFRefreshDaemonManager.InstallationState =
        PFRefreshDaemonManager.installationState()
    @State private var daemonStatusMessage: String?

    private var daemonInstalled: Bool {
        daemonInstallationState.isInstalled
    }

    private var daemonStatusLabel: String {
        switch daemonInstallationState {
        case .notInstalled:
            return "Not installed"
        case .installedOutdated:
            return "Needs update"
        case .installedCurrent:
            return "Installed"
        }
    }

    private var daemonStatusColor: Color {
        switch daemonInstallationState {
        case .installedCurrent:
            return Color(red: 0.18, green: 0.72, blue: 0.44)
        case .installedOutdated:
            return Color(red: 0.85, green: 0.56, blue: 0.18)
        case .notInstalled:
            return Color.secondary
        }
    }

    private var daemonActionLabel: String {
        switch daemonInstallationState {
        case .notInstalled:
            return "Install Daemon"
        case .installedOutdated, .installedCurrent:
            return "Update Daemon"
        }
    }

    private var clampedCustomDuration: Int {
        min(max(defaultCustomDurationMinutes, 1), 10_080)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("mControl")
                .font(.custom("Avenir Next Bold", size: 24))

            Text("This app updates /etc/hosts to block domains in active sessions.")
                .font(.custom("Avenir Next Regular", size: 14))

            Text("When an interval starts or ends, macOS may ask for administrator approval.")
                .font(.custom("Avenir Next Regular", size: 14))

            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Launch at Login", isOn: launchAtLoginBinding)
                        .font(.custom("Avenir Next Medium", size: 14))

                    Text("If enabled, mControl starts automatically after logging into macOS.")
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(.secondary)

                    Text("After enabling, sign out/in to verify startup behavior.")
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            GroupBox("Background PF Refresh") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(daemonStatusLabel)
                            .font(.custom("Avenir Next Medium", size: 14))
                            .foregroundStyle(daemonStatusColor)

                        Spacer()

                        Button(daemonActionLabel) {
                            installOrUpdatePFDaemon()
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.custom("Avenir Next Medium", size: 13))
                    }

                    Text("Installs a root launchd job to refresh PF rules every 1 minute without repeated password prompts.")
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(.secondary)

                    if let daemonStatusMessage {
                        Text(daemonStatusMessage)
                            .font(.custom("Avenir Next Medium", size: 12))
                            .foregroundStyle(daemonStatusColor)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Ask before Quit from menubar", isOn: $confirmQuitEnabled)
                        .font(.custom("Avenir Next Medium", size: 14))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default custom duration")
                            .font(.custom("Avenir Next Medium", size: 14))

                        Stepper(value: $defaultCustomDurationMinutes, in: 1 ... 10_080, step: 5) {
                            Text("\(formatDuration(clampedCustomDuration))")
                                .font(.custom("Avenir Next Regular", size: 13))
                        }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox("Live Status") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active groups: \(viewModel.activeSnapshots.count)")
                        .font(.custom("Avenir Next Regular", size: 14))

                    Text("Blocked domains: \(viewModel.activeDomains.count)")
                        .font(.custom("Avenir Next Regular", size: 14))

                    Text(viewModel.nextChangeSummary)
                        .font(.custom("Avenir Next Regular", size: 14))
                }
                .padding(.top, 4)
            }

            if let launchAtLoginErrorMessage {
                Text(launchAtLoginErrorMessage)
                    .font(.custom("Avenir Next Medium", size: 12))
                    .foregroundStyle(Color(red: 0.74, green: 0.26, blue: 0.23))
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
            daemonInstallationState = PFRefreshDaemonManager.installationState()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLoginManager.setEnabled(newValue)
                    launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
                    launchAtLoginErrorMessage = nil
                } catch {
                    launchAtLoginEnabled = LaunchAtLoginManager.isEnabled()
                    launchAtLoginErrorMessage = error.localizedDescription
                }
            }
        )
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes % (24 * 60) == 0 {
            return "\(minutes / (24 * 60)) day(s)"
        }

        if minutes % 60 == 0 {
            return "\(minutes / 60) hour(s)"
        }

        return "\(minutes) min"
    }

    private func installOrUpdatePFDaemon() {
        do {
            try PFRefreshDaemonManager.installOrUpdate()
            daemonInstallationState = PFRefreshDaemonManager.installationState()
            switch daemonInstallationState {
            case .installedCurrent:
                daemonStatusMessage = "PF daemon installed and up to date. PF refresh runs every 1 minute."
            case .installedOutdated:
                daemonStatusMessage = "Daemon files exist but version/config mismatch remains. Re-run update."
            case .notInstalled:
                daemonStatusMessage = "Daemon install command completed, but files were not detected."
            }
        } catch {
            daemonInstallationState = PFRefreshDaemonManager.installationState()
            daemonStatusMessage = error.localizedDescription
        }
    }
}
