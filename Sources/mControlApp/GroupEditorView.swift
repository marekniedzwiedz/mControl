import BlockingCore
import SwiftUI

struct GroupEditorView: View {
    let title: String
    let draft: GroupDraft
    let onCancel: () -> Void
    let onSave: (GroupDraft) -> Void

    @State private var name: String
    @State private var domainsText: String
    @State private var severity: BlockSeverity

    init(
        title: String,
        draft: GroupDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (GroupDraft) -> Void
    ) {
        self.title = title
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave

        _name = State(initialValue: draft.name)
        _domainsText = State(initialValue: draft.domainsText)
        _severity = State(initialValue: draft.severity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 24))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.custom("Avenir Next Medium", size: 12))

                TextField("Focus Work", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.custom("Avenir Next Regular", size: 14))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Domains (one per line)")
                    .font(.custom("Avenir Next Medium", size: 12))

                TextEditor(text: $domainsText)
                    .font(.custom("Avenir Next Regular", size: 13))
                    .padding(6)
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Severity")
                    .font(.custom("Avenir Next Medium", size: 12))

                Picker("Severity", selection: $severity) {
                    ForEach(BlockSeverity.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text(severity.description)
                    .font(.custom("Avenir Next Regular", size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    onSave(
                        GroupDraft(
                            groupID: draft.groupID,
                            name: name,
                            domainsText: domainsText,
                            severity: severity
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || domainsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
