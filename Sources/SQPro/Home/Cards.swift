import SwiftUI
import SQCore

private let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
private let cardHeight: CGFloat = 92

struct ConnectionCard: View {
    let profile: ConnectionProfile
    var showsGroup = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name.isEmpty ? profile.address : profile.name)
                    .font(.headline)
                    .lineLimit(1)
                if showsGroup, let group = profile.groupName {
                    Text(group)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Label(profile.user, systemImage: "person.fill")
                Label(profile.address, systemImage: "network")
            }
            .font(.callout)
            .labelStyle(CardLabelStyle())
            .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .topLeading)
            .padding(12)
            .background(alignment: .bottomTrailing) { Watermark(systemName: "cylinder.split.1x2.fill") }
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .glassEffect(glass(tint: profile.color.color), in: cardShape)
        .help(profile.defaultSchema.isEmpty ? profile.address : "\(profile.address) · \(profile.defaultSchema)")
    }
}

struct GroupCard: View {
    let name: String
    let count: Int
    let action: () -> Void
    /// Connection ids dropped onto the folder.
    let onDrop: ([String]) -> Bool
    @State private var isDropTarget = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                Text(count == 1 ? "1 Connection" : "\(count) Connections")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .topLeading)
            .padding(12)
            .background(alignment: .bottomTrailing) { Watermark(systemName: "folder.fill") }
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .glassEffect(glass(tint: .blue), in: cardShape)
        .dropDestination(for: String.self) { ids, _ in onDrop(ids) } isTargeted: { isDropTarget = $0 }
        .scaleEffect(isDropTarget ? 1.04 : 1)
        .animation(.snappy, value: isDropTarget)
    }
}

struct BackCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("back", systemImage: "chevron.left")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .topLeading)
                .padding(12)
                .background(alignment: .bottomTrailing) { Watermark(systemName: "folder.fill") }
                .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .glassEffect(glass(tint: .red), in: cardShape)
        .keyboardShortcut(.cancelAction)
        .help("Back to all connections (Esc)")
    }
}

private func glass(tint: Color?) -> Glass {
    guard let tint else { return .regular.interactive() }
    return .regular.tint(tint.opacity(0.45)).interactive()
}

/// The large faint icon in the bottom-right corner of each card.
private struct Watermark: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 52))
            .foregroundStyle(.primary.opacity(0.08))
            .padding(.trailing, 12)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
    }
}

private struct CardLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            configuration.title
                .lineLimit(1)
        }
    }
}
