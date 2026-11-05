import SwiftUI
import SQCore

/// Alter / Drop Schemas… from the schema tree: what will change, the SQL, then one click to run it.
/// Drop has no default button, so Return can't delete a database.
struct SchemaChangeSheet: View {
    let tab: ConnectionTab
    let change: SchemaChange

    @Environment(\.dismiss) private var dismiss
    @State private var details: [String: SchemaChange.Details] = [:]
    @State private var charsets: [(name: String, defaultCollation: String)] = []
    @State private var collations: [(name: String, charset: String)] = []
    @State private var charset = ""
    @State private var collation = ""
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var error: String?
    @State private var confirmProduction = false

    private var isDrop: Bool { change.kind == .drop }
    private var isProduction: Bool { tab.profile.color.isProduction }
    private var title: String {
        let noun = change.schemas.count == 1 ? "Schema" : "\(change.schemas.count) Schemas"
        return isDrop ? "Drop \(noun)" : "Alter \(noun)"
    }

    /// Alter only touches schemas whose defaults actually change.
    private var statements: [String] {
        if isDrop { return SchemaScript.drop(change.schemas) }
        let changed = change.schemas.filter { name in
            guard let current = details[name] else { return true }
            return current.charset != charset || current.collation != collation
        }
        return SchemaScript.alter(changed, charset: charset, collation: collation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.bold())
                Text(isDrop
                     ? "Deletes the schemas and every table, view and routine in them. This can't be undone."
                     : "Changes the default character set and collation. Only tables created later use them; existing tables keep theirs.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isProduction {
                    Label("\(tab.profile.name) is marked as production.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            schemaList

            if !isDrop { alterOptions }

            VStack(alignment: .leading, spacing: 4) {
                Text("SQL").font(.caption).foregroundStyle(.secondary)
                SQLCodeView(text: statements.isEmpty ? "-- Nothing to change" : SchemaScript.text(statements))
                    .frame(height: 96)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
            }

            if let error {
                Label {
                    Text(error).textSelection(.enabled)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .foregroundStyle(.red)
                Text("Statements before the failing one already ran; schema changes can't be rolled back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                actionButton
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
        .confirmationDialog("\(title) on \(tab.profile.name)?", isPresented: $confirmProduction) {
            Button(isDrop ? "Drop on Production" : "Alter on Production", role: .destructive, action: run)
        } message: {
            Text("This connection is marked as production.")
        }
    }

    private var schemaList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(change.schemas, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "cylinder.split.1x2")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(summary(name))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var alterOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Character set").gridColumnAlignment(.trailing)
                Picker("Character set", selection: $charset) {
                    if charset.isEmpty { Text("Mixed").tag("") }
                    ForEach(charsets, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .onChange(of: charset) { _, new in
                    // A collation belongs to one character set; switch to the new set's default.
                    if let set = charsets.first(where: { $0.name == new }), !collationFits(collation, set.name) {
                        collation = set.defaultCollation
                    }
                }
            }
            GridRow {
                Text("Collation")
                Picker("Collation", selection: $collation) {
                    if collation.isEmpty { Text("Mixed").tag("") }
                    ForEach(collations.filter { $0.charset == charset }, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .disabled(charset.isEmpty)
            }
        }
        .disabled(isLoading)
    }

    @ViewBuilder
    private var actionButton: some View {
        let button = Button {
            if isProduction { confirmProduction = true } else { run() }
        } label: {
            if isRunning { ProgressView().controlSize(.small) } else { Text(isDrop ? title : "Apply") }
        }
        .disabled(isRunning || isLoading || statements.isEmpty)
        if isDrop {
            button.buttonStyle(.borderedProminent).tint(.red)
        } else {
            button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    private func summary(_ name: String) -> String {
        guard let detail = details[name] else { return isLoading ? "…" : "" }
        if !isDrop { return "\(detail.charset) · \(detail.collation)" }
        let parts = [(detail.tables, "table"), (detail.views, "view"), (detail.routines, "routine")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }

    private func collationFits(_ collation: String, _ charset: String) -> Bool {
        collations.contains { $0.name == collation && $0.charset == charset }
    }

    private func load() async {
        details = await tab.schemaDetails(change.schemas)
        if !isDrop {
            (charsets, collations) = await tab.characterSets()
            // Start from the schemas' current defaults; "Mixed" when they differ.
            let current = change.schemas.compactMap { details[$0] }
            if let first = current.first, current.allSatisfy({ $0.charset == first.charset }) { charset = first.charset }
            if let first = current.first, current.allSatisfy({ $0.collation == first.collation }) { collation = first.collation }
        }
        isLoading = false
    }

    private func run() {
        isRunning = true
        error = nil
        Task {
            let failure = await tab.runSchemaScript(statements)
            isRunning = false
            if let failure {
                error = failure
                details = await tab.schemaDetails(change.schemas)
            } else {
                dismiss()
            }
        }
    }
}
