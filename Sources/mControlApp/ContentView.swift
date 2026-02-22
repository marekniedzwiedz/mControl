import BlockingCore
import SwiftUI

private struct GroupSheetState: Identifiable {
    let id = UUID()
    let draft: GroupDraft
    let title: String
}

private struct ScheduleSheetState: Identifiable {
    let id = UUID()
    let group: BlockGroup
    let startDate: Date
    let endDate: Date
}

private struct QuickDurationSheetState: Identifiable {
    let id = UUID()
    let group: BlockGroup
    let defaultMinutes: Int
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var groupSheet: GroupSheetState?
    @State private var scheduleSheet: ScheduleSheetState?
    @State private var quickDurationSheet: QuickDurationSheetState?
    @State private var alertMessage: String = ""
    @State private var isAlertVisible = false

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
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    groupsCard
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 760)
        .sheet(item: $groupSheet) { sheet in
            GroupEditorView(
                title: sheet.title,
                draft: sheet.draft,
                onCancel: { groupSheet = nil },
                onSave: { draft in
                    viewModel.saveGroup(draft)
                    groupSheet = nil
                }
            )
            .frame(width: 460, height: 520)
        }
        .sheet(item: $scheduleSheet) { sheet in
            ScheduleIntervalView(
                groupName: sheet.group.name,
                startDate: sheet.startDate,
                endDate: sheet.endDate,
                onCancel: { scheduleSheet = nil },
                onSave: { start, end in
                    viewModel.scheduleInterval(group: sheet.group, startDate: start, endDate: end)
                    scheduleSheet = nil
                }
            )
            .frame(width: 460, height: 380)
        }
        .sheet(item: $quickDurationSheet) { sheet in
            QuickDurationView(
                groupName: sheet.group.name,
                defaultMinutes: sheet.defaultMinutes,
                onCancel: { quickDurationSheet = nil },
                onStart: { minutes in
                    viewModel.startQuickInterval(group: sheet.group, minutes: minutes)
                    quickDurationSheet = nil
                }
            )
            .frame(width: 460, height: 260)
        }
        .onReceive(viewModel.$errorMessage) { newValue in
            guard let newValue else {
                return
            }
            alertMessage = newValue
            isAlertVisible = true
        }
        .alert("mControl", isPresented: $isAlertVisible) {
            Button("OK") {
                viewModel.clearMessages()
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("mControl")
                        .font(.custom("Avenir Next Demi Bold", size: 24))
                        .foregroundStyle(.white)

                    Text("Menubar website blocker")
                        .font(.custom("Avenir Next Regular", size: 13))
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer()

                Button {
                    groupSheet = GroupSheetState(draft: .createDefault(), title: "New Block Group")
                } label: {
                    Label("New Group", systemImage: "plus.circle.fill")
                        .font(.custom("Avenir Next Demi Bold", size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.26, green: 0.72, blue: 0.54))
            }

            HStack(spacing: 14) {
                statItem(title: "Active Sessions", value: "\(viewModel.activeSnapshots.count)")
                statItem(title: "Domains Blocked", value: "\(viewModel.activeDomains.count)")
                statItem(title: "Next Change", value: viewModel.nextChangeSummary.replacingOccurrences(of: "Next change ", with: ""))
            }

            HStack(spacing: 10) {
                Text(viewModel.hostsStatusMessage)
                    .font(.custom("Avenir Next Medium", size: 12))
                    .foregroundStyle(
                        viewModel.hasManagedHostsBlock
                            ? Color(red: 0.63, green: 0.89, blue: 0.74)
                            : Color(red: 0.96, green: 0.73, blue: 0.55)
                    )
                    .lineLimit(2)
            }

            if let infoMessage = viewModel.infoMessage {
                Text(infoMessage)
                    .font(.custom("Avenir Next Medium", size: 12))
                    .foregroundStyle(Color(red: 0.63, green: 0.89, blue: 0.74))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.02, green: 0.09, blue: 0.15).opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var groupsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Block Groups")
                .font(.custom("Avenir Next Demi Bold", size: 17))
                .foregroundStyle(.white)

            if viewModel.groups.isEmpty {
                Text("Create your first group to start blocking websites.")
                    .font(.custom("Avenir Next Regular", size: 13))
                    .foregroundStyle(.white.opacity(0.75))
            }

            ForEach(viewModel.groups) { group in
                GroupCardView(
                    group: group,
                    activeSnapshots: viewModel.activeSnapshots(for: group),
                    remainingText: { viewModel.formatRemaining(until: $0) },
                    onStart1h: { viewModel.startQuickInterval(group: group, minutes: 60) },
                    onStart4h: { viewModel.startQuickInterval(group: group, minutes: 240) },
                    onStart24h: { viewModel.startQuickInterval(group: group, minutes: 1_440) },
                    onStart7d: { viewModel.startQuickInterval(group: group, minutes: 10_080) },
                    onStartCustom: {
                        quickDurationSheet = QuickDurationSheetState(group: group, defaultMinutes: 60)
                    },
                    onSchedule: {
                        scheduleSheet = ScheduleSheetState(
                            group: group,
                            startDate: viewModel.now,
                            endDate: viewModel.now.addingTimeInterval(60 * 60)
                        )
                    },
                    onEdit: {
                        groupSheet = GroupSheetState(draft: .from(group: group), title: "Edit Block Group")
                    },
                    onDelete: { viewModel.deleteGroup(group) },
                    onStopInterval: { viewModel.stopInterval($0) }
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.02, green: 0.09, blue: 0.15).opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.custom("Avenir Next Medium", size: 11))
                .foregroundStyle(.white.opacity(0.72))

            Text(value)
                .font(.custom("Avenir Next Demi Bold", size: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupCardView: View {
    let group: BlockGroup
    let activeSnapshots: [ActiveGroupSnapshot]
    let remainingText: (Date) -> String
    let onStart1h: () -> Void
    let onStart4h: () -> Void
    let onStart24h: () -> Void
    let onStart7d: () -> Void
    let onStartCustom: () -> Void
    let onSchedule: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onStopInterval: (ActiveGroupSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.name)
                    .font(.custom("Avenir Next Demi Bold", size: 15))
                    .foregroundStyle(.white)

                SeverityPill(severity: group.severity)

                Spacer()

                Text("\(group.domains.count) domains")
                    .font(.custom("Avenir Next Medium", size: 11))
                    .foregroundStyle(.white.opacity(0.64))
            }

            Text(group.domains.joined(separator: ", "))
                .font(.custom("Avenir Next Regular", size: 12))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)

            if !activeSnapshots.isEmpty {
                ForEach(activeSnapshots) { snapshot in
                    HStack(spacing: 8) {
                        Text("Active: \(remainingText(snapshot.endsAt)) left")
                            .font(.custom("Avenir Next Medium", size: 12))
                            .foregroundStyle(Color(red: 0.90, green: 0.92, blue: 0.72))

                        Spacer()

                        if snapshot.severity == .flexible {
                            Button("Stop") {
                                onStopInterval(snapshot)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.73, green: 0.32, blue: 0.22))
                            .controlSize(.small)
                        } else {
                            Text("Strict")
                                .font(.custom("Avenir Next Demi Bold", size: 11))
                                .foregroundStyle(Color(red: 0.96, green: 0.73, blue: 0.55))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("1h", action: onStart1h)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.16, green: 0.56, blue: 0.47))

                Button("4h", action: onStart4h)
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                Button("24h", action: onStart24h)
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                Button("7d", action: onStart7d)
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                Button("Custom", action: onStartCustom)
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                Button("Schedule", action: onSchedule)
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                Spacer()

                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                    .tint(Color(red: 0.50, green: 0.76, blue: 0.93))

                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.66, green: 0.24, blue: 0.24))
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.01, green: 0.07, blue: 0.12).opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
        )
    }
}

private struct SeverityPill: View {
    let severity: BlockSeverity

    var body: some View {
        Text(severity.title)
            .font(.custom("Avenir Next Demi Bold", size: 10))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(
                Capsule(style: .continuous)
                    .fill(severity == .strict ? Color(red: 0.68, green: 0.24, blue: 0.19) : Color(red: 0.20, green: 0.47, blue: 0.68))
            )
    }
}
