import SwiftUI

struct ScheduleIntervalView: View {
    let groupName: String
    let onCancel: () -> Void
    let onSave: (Date, Date) -> Void

    @State private var startDate: Date
    @State private var endDate: Date

    init(
        groupName: String,
        startDate: Date,
        endDate: Date,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Date, Date) -> Void
    ) {
        self.groupName = groupName
        self.onCancel = onCancel
        self.onSave = onSave
        _startDate = State(initialValue: startDate)
        _endDate = State(initialValue: endDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule \(groupName)")
                .font(.custom("Avenir Next Demi Bold", size: 24))

            Text("Run this block group on a custom interval.")
                .font(.custom("Avenir Next Regular", size: 13))
                .foregroundStyle(.secondary)

            DatePicker(
                "Start",
                selection: $startDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.custom("Avenir Next Regular", size: 14))

            DatePicker(
                "End",
                selection: $endDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.custom("Avenir Next Regular", size: 14))

            HStack(spacing: 8) {
                Button("Now + 1h") {
                    startDate = Date()
                    endDate = Date().addingTimeInterval(60 * 60)
                }
                .buttonStyle(.bordered)

                Button("Now + 4h") {
                    startDate = Date()
                    endDate = Date().addingTimeInterval(4 * 60 * 60)
                }
                .buttonStyle(.bordered)

                Button("Now + 24h") {
                    startDate = Date()
                    endDate = Date().addingTimeInterval(24 * 60 * 60)
                }
                .buttonStyle(.bordered)

                Button("Now + 7d") {
                    startDate = Date()
                    endDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    onSave(startDate, endDate)
                }
                .buttonStyle(.borderedProminent)
                .disabled(endDate <= startDate)
            }
        }
        .padding(20)
    }
}
