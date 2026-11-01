import AppKit
import SQCore

/// Gives autocomplete its schema data. `ConnectionTab` loads columns one schema at a time, on first use.
protocol CompletionSource: AnyObject {
    func completionCatalog() -> CompletionCatalog
    /// Loads the schemas' tables and columns, then calls `done`.
    func loadCompletionSchemas(_ schemas: [String], done: @escaping () -> Void)
}

/// The autocomplete list under the cursor. It never takes focus: the text view keeps typing and forwards
/// ↑ ↓ Return Tab Esc here while the list is open.
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 22
    private static let visibleRows = 10
    private static let width: CGFloat = 400

    private weak var textView: SQLTextView?
    weak var source: CompletionSource?

    private var panel: CompletionPanel?
    private var tableView: CompletionTableView?
    /// The table reloads on every change: it may lay out (and ask for rows) at any time, even while hidden.
    private var items: [CompletionItem] = [] {
        didSet { tableView?.reloadData() }
    }
    private var request: CompletionRequest?
    /// Opened with Esc / ⌥Esc / ⌃Space: stays open with nothing typed.
    private var isManual = false
    private var observers: [NSObjectProtocol] = []

    init(textView: SQLTextView) {
        self.textView = textView
    }

    var isVisible: Bool { panel?.isVisible == true }

    #if DEBUG
    var debugNames: [String] { (isVisible ? ["(visible)"] : ["(hidden)"]) + items.map(\.name) }
    #endif

    /// Recomputes the list for the cursor position; closes it when there's nothing to offer.
    func update(manual: Bool = false) {
        if manual { isManual = true }
        guard let textView, let source else { return close() }
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let request = SQLCompletion.request(in: textView.string, at: selection.location),
              isManual || !request.prefix.isEmpty || !request.qualifier.isEmpty
        else { return close() }

        let catalog = source.completionCatalog()
        let missing = SQLCompletion.schemasToLoad(for: request, in: catalog)
        if !missing.isEmpty {
            let cursor = selection.location
            source.loadCompletionSchemas(missing) { [weak self] in
                // Columns arrived: refresh if the user is still at the same spot.
                guard let self, let textView = self.textView, textView.selectedRange().location == cursor,
                      textView.window?.firstResponder === textView
                else { return }
                self.update()
            }
        }

        let previous = selectedItem
        items = SQLCompletion.suggestions(for: request, in: catalog)
        self.request = request
        guard !items.isEmpty else { return close() }
        show(at: request.range.lowerBound)
        let row = previous.flatMap { items.firstIndex(of: $0) } ?? 0
        tableView?.selectRowIndexes([row], byExtendingSelection: false)
        tableView?.scrollRowToVisible(row)
    }

    func close() {
        isManual = false
        request = nil
        items = []
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func moveSelection(by delta: Int) {
        guard let tableView, !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Inserts the selected item. Returns `false` (so Return still makes a new line) when the typed word
    /// already is the selected item.
    @discardableResult
    func accept() -> Bool {
        guard let textView, let request, let item = selectedItem else { return false }
        let range = NSRange(location: request.range.lowerBound, length: request.range.count)
        if (textView.string as NSString).substring(with: range) == item.insertion {
            close()
            return false
        }
        close()
        textView.insertCompletion(item.insertion, replacing: range)
        return true
    }

    private var selectedItem: CompletionItem? {
        guard let row = tableView?.selectedRow, row >= 0, row < items.count else { return nil }
        return items[row]
    }

    // MARK: Window

    private func show(at location: Int) {
        guard let textView, let window = textView.window else { return }
        let panel = self.panel ?? makePanel()

        let anchor = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        let height = CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight + 10
        // Line the names up with the typed word: the icon column sits to its left.
        var frame = NSRect(x: anchor.minX - 33, y: anchor.minY - height - 2, width: Self.width, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = anchor.maxY + 2 }
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
            observe(window: window, textView: textView)
        }
        panel.orderFront(nil)
    }

    private func observe(window: NSWindow, textView: NSTextView) {
        let center = NotificationCenter.default
        let closeList: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: closeList),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: closeList),
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView, queue: .main, using: closeList),
        ]
    }

    private func makePanel() -> CompletionPanel {
        let panel = CompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true

        let tableView = CompletionTableView()
        tableView.addTableColumn(NSTableColumn(identifier: .init("item")))
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)

        let glass = NSGlassEffectView()
        glass.cornerRadius = 10
        glass.contentView = scrollView
        panel.contentView = glass

        self.panel = panel
        self.tableView = tableView
        return panel
    }

    @objc private func clicked() {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
        accept()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.show(items[row])
        return cell
    }
}

/// Never becomes key, so the editor keeps focus while the list is open.
private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the click that picks an item even though its window isn't key.
private final class CompletionTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A rounded, inset selection like a menu's, blue even though the panel is never key.
private final class CompletionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

private final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = SQLTheme.font
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        for view in [icon, name, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 170),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            name.textColor = selected ? .white : .labelColor
            detail.textColor = selected ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
        }
    }

    func show(_ item: CompletionItem) {
        let (symbol, color) = Self.icon(for: item.kind)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        name.stringValue = item.name
        detail.stringValue = item.detail
    }

    private static func icon(for kind: CompletionItem.Kind) -> (String, NSColor) {
        switch kind {
        case .column: ("c.square.fill", .systemOrange)
        case .table: ("tablecells", .systemBlue)
        case .view: ("eye", .systemTeal)
        case .schema: ("cylinder.split.1x2", .systemGray)
        case .keyword: ("k.square.fill", .systemPink)
        case .function: ("f.cursive", .systemPurple)
        }
    }
}
