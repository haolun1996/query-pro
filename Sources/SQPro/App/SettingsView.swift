import SwiftUI

/// App settings (SQ Pro › Settings…, ⌘,). Values live in UserDefaults via `@AppStorage`.
struct SettingsView: View {
    @AppStorage(SettingsKey.showsDDL) private var showsDDL = true

    var body: some View {
        Form {
            Section("Table Info") {
                Toggle("Show DDL section", isOn: $showsDDL)
                Text("The CREATE TABLE statement, shown as the last section when you open a table's info.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

enum SettingsKey {
    static let showsDDL = "showsDDL"
}
