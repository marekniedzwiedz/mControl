import BlockingCore
import AppKit
import Darwin
import SwiftUI

private enum QuickDurationTarget {
    case group(BlockGroup)
    case allGroups
}

private struct QuickDurationSheetState: Identifiable {
    let id = UUID()
    let target: QuickDurationTarget
    let defaultMinutes: Int
}

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var quickDurationSheet: QuickDurationSheetState?
    @State private var isQuitConfirmationVisible = false
    @AppStorage("confirmQuitEnabled") private var confirmQuitEnabled: Bool = true
    @AppStorage("defaultCustomDurationMinutes") private var defaultCustomDurationMinutes: Int = 60

    private let actionGreen = Color(red: 0.18, green: 0.64, blue: 0.44)
    private let warningRed = Color(red: 0.73, green: 0.32, blue: 0.22)
    private let cardFill = Color(red: 0.02, green: 0.09, blue: 0.15).opacity(0.80)
    private let rowFill = Color.white.opacity(0.08)
    private let cardStroke = Color.white.opacity(0.22)
    private let secondaryText = Color.white.opacity(0.72)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.12, blue: 0.22),
                    Color(red: 0.08, green: 0.24, blue: 0.34),
                    Color(red: 0.18, green: 0.34, blue: 0.38)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headerSection
                    allGroupsSection
                    activeSessionSection
                    groupsSection
                    footerSection
                }
                .padding(12)
            }
            .disabled(isQuitConfirmationVisible)
            .fixedSize(horizontal: false, vertical: true)

            if isQuitConfirmationVisible {
                quitConfirmationOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.16), value: isQuitConfirmationVisible)
        .sheet(item: $quickDurationSheet) { sheet in
            quickDurationSheetView(sheet)
                .frame(width: 440, height: 280)
        }
    }

    @ViewBuilder
    private func quickDurationSheetView(_ sheet: QuickDurationSheetState) -> some View {
        switch sheet.target {
        case let .group(group):
            QuickDurationView(
                groupName: group.name,
                defaultMinutes: sheet.defaultMinutes,
                onCancel: { quickDurationSheet = nil },
                onStart: { minutes in
                    viewModel.startQuickInterval(group: group, minutes: minutes)
                    quickDurationSheet = nil
                }
            )
        case .allGroups:
            QuickDurationView(
                groupName: "All Groups",
                defaultMinutes: sheet.defaultMinutes,
                onCancel: { quickDurationSheet = nil },
                onStart: { minutes in
                    viewModel.startAllGroups(minutes: minutes)
                    quickDurationSheet = nil
                }
            )
        }
    }

    private var headerSection: some View {
        sectionCard {
            HStack(alignment: .center) {
                Label("mControl", systemImage: viewModel.menuBarSymbolName)
                    .font(.custom("Avenir Next Demi Bold", size: 20))
                    .foregroundStyle(.white)

                Spacer()

                Text(viewModel.activeSnapshots.isEmpty ? "Idle" : "Active")
                    .font(.custom("Avenir Next Demi Bold", size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(
                        Capsule(style: .continuous)
                            .fill(viewModel.activeSnapshots.isEmpty ? Color.gray.opacity(0.65) : actionGreen)
                    )
            }
        }
    }

    private var allGroupsSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("All Groups")
                    .font(.custom("Avenir Next Demi Bold", size: 13))
                    .foregroundStyle(.white)

                if viewModel.groups.isEmpty {
                    Text("Create your first group in Dashboard")
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(secondaryText)
                } else {
                    HStack(spacing: 6) {
                        startAllButton(title: "1h", minutes: 60)
                        startAllButton(title: "4h", minutes: 240)
                        startAllButton(title: "24h", minutes: 1_440)
                        startAllButton(title: "7d", minutes: 10_080)
                    }

                    HStack {
                        Button("Custom") {
                            quickDurationSheet = QuickDurationSheetState(
                                target: .allGroups,
                                defaultMinutes: clampedCustomDurationMinutes
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                        Spacer()
                    }
                }
            }
        }
    }

    private var activeSessionSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Active Sessions")
                        .font(.custom("Avenir Next Demi Bold", size: 13))
                        .foregroundStyle(.white)

                    Spacer()

                    if !viewModel.stoppableActiveSnapshots.isEmpty {
                        Button("Stop All") {
                            viewModel.stopAllStoppableSessions()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(warningRed)
                        .controlSize(.small)
                    }
                }

                if viewModel.activeSnapshots.isEmpty {
                    Text("No active sessions")
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(secondaryText)
                } else {
                    ForEach(viewModel.activeSnapshots) { snapshot in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.groupName)
                                    .font(.custom("Avenir Next Demi Bold", size: 12))
                                    .foregroundStyle(.white)
                                Text("\(viewModel.formatRemaining(until: snapshot.endsAt)) left")
                                    .font(.custom("Avenir Next Regular", size: 11))
                                    .foregroundStyle(secondaryText)
                            }

                            Spacer()

                            if viewModel.isStoppable(snapshot) {
                                Button("Stop") {
                                    viewModel.stopInterval(snapshot)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(warningRed)
                                .controlSize(.small)
                            } else {
                                Text("Strict")
                                    .font(.custom("Avenir Next Demi Bold", size: 11))
                                    .foregroundStyle(Color(red: 0.96, green: 0.73, blue: 0.55))
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(rowFill)
                        )
                    }
                }
            }
        }
    }

    private var groupsSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Groups")
                        .font(.custom("Avenir Next Demi Bold", size: 13))
                        .foregroundStyle(.white)

                    Spacer()

                    Text(viewModel.nextChangeSummary)
                        .font(.custom("Avenir Next Regular", size: 11))
                        .foregroundStyle(secondaryText)
                }

                if viewModel.groups.isEmpty {
                    Text("Create your first group in Dashboard")
                        .font(.custom("Avenir Next Regular", size: 12))
                        .foregroundStyle(secondaryText)
                }

                ForEach(viewModel.groups) { group in
                    let activeForGroup = viewModel.activeSnapshots(for: group)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(group.name)
                                .font(.custom("Avenir Next Demi Bold", size: 12))
                                .foregroundStyle(.white)

                            Spacer()

                            if let soonestEnding = activeForGroup.min(by: { $0.endsAt < $1.endsAt }) {
                                Text("Active • \(viewModel.formatRemaining(until: soonestEnding.endsAt))")
                                    .font(.custom("Avenir Next Medium", size: 11))
                                    .foregroundStyle(actionGreen)
                            } else {
                                Text("Idle")
                                    .font(.custom("Avenir Next Medium", size: 11))
                                    .foregroundStyle(secondaryText)
                            }
                        }

                        HStack(spacing: 6) {
                            startButton(group: group, title: "1h", minutes: 60)
                            startButton(group: group, title: "4h", minutes: 240)
                            startButton(group: group, title: "24h", minutes: 1_440)
                            startButton(group: group, title: "7d", minutes: 10_080)
                        }

                        HStack(spacing: 6) {
                            Button("Custom") {
                                quickDurationSheet = QuickDurationSheetState(
                                    target: .group(group),
                                    defaultMinutes: clampedCustomDurationMinutes
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                            Spacer()
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(rowFill)
                    )
                }
            }
        }
    }

    private var footerSection: some View {
        sectionCard {
            HStack(spacing: 8) {
                footerActionButton(
                    "Settings",
                    systemImage: "gearshape.fill",
                    fill: Color.white.opacity(0.12),
                    stroke: Color.white.opacity(0.25)
                ) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }

                footerActionButton(
                    "Dashboard",
                    systemImage: "rectangle.stack.fill",
                    fill: Color(red: 0.11, green: 0.33, blue: 0.62),
                    stroke: Color.white.opacity(0.28)
                ) {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }

                Spacer()

                footerActionButton(
                    "Quit",
                    systemImage: "power",
                    fill: Color(red: 0.35, green: 0.17, blue: 0.17),
                    stroke: Color.white.opacity(0.24)
                ) {
                    requestQuit()
                }
            }
        }
    }

    private func startButton(group: BlockGroup, title: String, minutes: Int) -> some View {
        Button(title) {
            viewModel.startQuickInterval(group: group, minutes: minutes)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(actionGreen)
    }

    private func startAllButton(title: String, minutes: Int) -> some View {
        Button(title) {
            viewModel.startAllGroups(minutes: minutes)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(actionGreen)
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(cardStroke, lineWidth: 1)
                    )
            )
    }

    private var quitConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .onTapGesture {
                    isQuitConfirmationVisible = false
                }

            VStack(alignment: .leading, spacing: 12) {
                Text("Quit mControl?")
                    .font(.custom("Avenir Next Demi Bold", size: 16))
                    .foregroundStyle(.white)

                Text("Any active strict sessions will continue until they end.")
                    .font(.custom("Avenir Next Regular", size: 13))
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Cancel") {
                        isQuitConfirmationVisible = false
                    }
                    .buttonStyle(.plain)
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.14))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
                            )
                    )

                    Spacer()

                    Button("Quit") {
                        terminateApplication()
                    }
                    .buttonStyle(.plain)
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(warningRed)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                            )
                    )
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.01, green: 0.07, blue: 0.12).opacity(0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 20)
        }
    }

    private var clampedCustomDurationMinutes: Int {
        min(max(defaultCustomDurationMinutes, 1), 10_080)
    }

    private func footerActionButton(
        _ title: String,
        systemImage: String,
        fill: Color,
        stroke: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.custom("Avenir Next Demi Bold", size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(fill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(stroke, lineWidth: 1)
                )
        )
    }

    private func requestQuit() {
        if confirmQuitEnabled {
            isQuitConfirmationVisible = true
        } else {
            terminateApplication()
        }
    }

    private func terminateApplication() {
        isQuitConfirmationVisible = false
        NSApp.terminate(nil)

        // Some MenuBarExtra + alert combinations may ignore terminate.
        // Fallback to hard exit if app is still alive shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if NSApp.isRunning {
                exit(EXIT_SUCCESS)
            }
        }
    }
}
