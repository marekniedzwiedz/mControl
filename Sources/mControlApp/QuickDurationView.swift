import SwiftUI

struct QuickDurationView: View {
    let groupName: String
    let onCancel: () -> Void
    let onStart: (Int) -> Void

    @State private var minutesText: String

    init(
        groupName: String,
        defaultMinutes: Int,
        onCancel: @escaping () -> Void,
        onStart: @escaping (Int) -> Void
    ) {
        self.groupName = groupName
        self.onCancel = onCancel
        self.onStart = onStart
        _minutesText = State(initialValue: String(max(1, defaultMinutes)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start \(groupName)")
                .font(.custom("Avenir Next Demi Bold", size: 24))

            Text("Set a custom duration in minutes.")
                .font(.custom("Avenir Next Regular", size: 13))
                .foregroundStyle(.secondary)

            TextField("Minutes", text: $minutesText)
                .textFieldStyle(.roundedBorder)
                .font(.custom("Avenir Next Regular", size: 14))

            HStack(spacing: 8) {
                quickButton(title: "1h", minutes: 60)
                quickButton(title: "4h", minutes: 240)
                quickButton(title: "24h", minutes: 1_440)
                quickButton(title: "7d", minutes: 10_080)
            }
            .controlSize(.small)

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Start") {
                    onStart(parsedMinutes)
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedMinutes <= 0)
            }
        }
        .padding(20)
    }

    private var parsedMinutes: Int {
        Int(minutesText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func quickButton(title: String, minutes: Int) -> some View {
        Button(title) {
            minutesText = String(minutes)
        }
        .buttonStyle(.bordered)
    }
}
