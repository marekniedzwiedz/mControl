import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @AppStorage("confirmQuitEnabled") private var confirmQuitEnabled: Bool = true
    @AppStorage("defaultCustomDurationMinutes") private var defaultCustomDurationMinutes: Int = 60

    @State private var launchAtLoginEnabled: Bool = LaunchAtLoginManager.isEnabled()
    @State private var launchAtLoginErrorMessage: String?
    @State private var daemonInstalled: Bool = PFRefreshDaemonManager.isInstalled()
    @State private var daemonStatusMessage: String?

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
                        Text(daemonInstalled ? "Installed" : "Not installed")
                            .font(.custom("Avenir Next Medium", size: 14))
                            .foregroundStyle(
                                daemonInstalled
                                    ? Color(red: 0.18, green: 0.72, blue: 0.44)
                                    : Color.secondary
                            )

                        Spacer()

                        Button(daemonInstalled ? "Update Daemon" : "Install Daemon") {
                            installOrUpdatePFDaemon()
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.custom("Avenir Next Medium", size: 13))
                    }

                    Text("Installs a root launchd job to refresh PF rules every 1 hour without repeated password prompts.")
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(.secondary)

                    if let daemonStatusMessage {
                        Text(daemonStatusMessage)
                            .font(.custom("Avenir Next Medium", size: 12))
                            .foregroundStyle(
                                daemonInstalled
                                    ? Color(red: 0.18, green: 0.72, blue: 0.44)
                                    : Color(red: 0.74, green: 0.26, blue: 0.23)
                            )
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
            daemonInstalled = PFRefreshDaemonManager.isInstalled()
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
            daemonInstalled = PFRefreshDaemonManager.isInstalled()
            daemonStatusMessage = daemonInstalled
                ? "PF daemon installed. Hourly PF refresh now runs in background."
                : "Daemon install command completed, but files were not detected."
        } catch {
            daemonInstalled = PFRefreshDaemonManager.isInstalled()
            daemonStatusMessage = error.localizedDescription
        }
    }
}
