import SwiftUI
import SQCore

/// "Apply SQL Script to Database": review (and optionally edit) the generated statements, then run them
/// in one transaction. On error everything is rolled back and the sheet stays open with the message.
struct ApplyChangesSheet: View {
    let tab: ConnectionTab
    let document: QueryDocument
    let resultTab: ResultTab

    @Environment(\.dismiss) private var dismiss
    @State private var script = ""
    @State private var error: String?
    @State private var isApplying = false
    @State private var confirmProduction = false

    private var isProduction: Bool { tab.profile.color.isProduction }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apply SQL Script to Database")
                    .font(.title3.bold())
                Text("Review the SQL statements that will be applied. You can also change them before running.")
                    .foregroundStyle(.secondary)
                if isProduction {
                    Label("\(tab.profile.name) is marked as production.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            SQLTextEditor(text: $script)
                .frame(minHeight: 220)
                .clipShape(.rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }

            if let error {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .foregroundStyle(.red)
                Text("Nothing was changed: the whole script was rolled back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Runs in one transaction")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Go Back", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isApplying)
                Button {
                    if isProduction { confirmProduction = true } else { apply() }
                } label: {
                    if isApplying { ProgressView().controlSize(.small) } else { Text("Apply") }
                }
                .buttonStyle(.borderedProminent)
                .tint(isProduction ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .onAppear { script = resultTab.changeScript() }
        .confirmationDialog("Apply changes to \(tab.profile.name)?", isPresented: $confirmProduction) {
            Button("Apply to Production", role: .destructive, action: apply)
        } message: {
            Text("This connection is marked as production.")
        }
    }

    private func apply() {
        isApplying = true
        error = nil
        Task {
            let failure = await tab.applyChanges(script, to: resultTab, in: document)
            isApplying = false
            if let failure {
                error = failure
            } else {
                dismiss()
            }
        }
    }
}
