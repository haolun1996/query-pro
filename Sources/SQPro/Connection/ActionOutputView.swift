import SwiftUI

/// The Action Output panel: one row per statement run, like Workbench's.
struct ActionOutputView: View {
    let tab: ConnectionTab

    private static let timeFormat = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Action Output")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", systemImage: "trash") { tab.clearLog() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(tab.log.isEmpty)
                    .help("Clear the output")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Table(tab.log.reversed()) {
                TableColumn("") { entry in
                    statusIcon(entry.status)
                }
                .width(18)
                TableColumn("#") { entry in
                    Text("\(entry.index)").monospacedDigit()
                }
                .width(min: 24, ideal: 30, max: 50)
                TableColumn("Time") { entry in
                    Text(entry.time, format: Self.timeFormat).monospacedDigit()
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Action") { entry in
                    Text(entry.action).lineLimit(1).help(entry.action)
                }
                .width(min: 120, ideal: 420)
                TableColumn("Response") { entry in
                    Text(entry.response)
                        .lineLimit(1)
                        .foregroundStyle(entry.status == .error ? .red : .primary)
                        .help(entry.response)
                }
                .width(min: 120, ideal: 320)
                TableColumn("Duration") { entry in
                    Text(entry.duration.map(Self.format) ?? "").monospacedDigit()
                }
                .width(min: 60, ideal: 90, max: 140)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .font(.callout)
            .contextMenu(forSelectionType: ActionLogEntry.ID.self) { ids in
                Button("Copy Action") { copy(ids) { $0.action } }
                Button("Copy Response") { copy(ids) { $0.response } }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: ActionLogEntry.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f sec", seconds)
    }

    private func copy(_ ids: Set<ActionLogEntry.ID>, _ field: (ActionLogEntry) -> String) {
        let text = tab.log.filter { ids.contains($0.id) }.map(field).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
