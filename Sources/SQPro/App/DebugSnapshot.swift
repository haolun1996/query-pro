#if DEBUG
import AppKit
import SwiftUI
import SQCore

/// Debug-only: lets a script drive the app and capture the window without Screen Recording permission.
///
///     SQPRO_OPEN="Local POS"          open this saved connection
///     SQPRO_OPEN_TEMP=root@localhost:3306   or a throwaway one that is never saved
///     SQPRO_SQL="select 1;"           put this in the editor and run it
///     SQPRO_DEMO_EDITS=1              after SQPRO_SQL: edit a cell, add a row, mark a row deleted (in memory)
///     SQPRO_DEMO_EDITS=fail           …and also set a column to NULL
///     SQPRO_DEMO_VALUE="…"            the text written into the edited cell
///     SQPRO_APPLY=1                   then apply them for real and print the outcome (scratch databases only!)
///     SQPRO_BOTTOM=ai|history         show the AI Activity or History panel
///     SQPRO_DROP_SQL="select 1;"      after SQPRO_SQL: kill the query connection server-side, then run this
///     SQPRO_IMPORT=schema.table:/path.csv   open the CSV import sheet (SQPRO_IMPORT_RUN=1 also runs it and prints the outcome;
///                                     SQPRO_IMPORT_DUPLICATES=stop|skip|replace)
///     SQPRO_TABLE_INFO=pos.admins     open that table's info tab
///     SQPRO_TABLE_SECTION=Indexes     …on this section
///     SQPRO_TYPE="select * from ad"   type this into the editor key by key (autocomplete opens) and print the list
///     SQPRO_SAVED_QUERIES=1           open the Saved Queries popover (=save: on its save form)
///     SQPRO_SNAPSHOT=/path/out.png    save the window as a PNG (other windows, e.g. popovers, as out-1.png …), then quit
///     SQPRO_SNAPSHOT_DELAY=4          seconds to wait first (default 4)
enum DebugSnapshot {
    @MainActor
    static func run(workspace: Workspace, connections: ConnectionsModel) async {
        let environment = ProcessInfo.processInfo.environment
        var target = environment["SQPRO_OPEN"].flatMap { name in connections.profiles.first { $0.name == name } }
        if let spec = environment["SQPRO_OPEN_TEMP"], let at = spec.firstIndex(of: "@") {
            let address = spec[spec.index(after: at)...].split(separator: ":")
            target = ConnectionProfile(
                name: "Temp \(spec)",
                host: String(address.first ?? "localhost"),
                port: address.count > 1 ? Int(address[1]) ?? 3306 : 3306,
                user: String(spec[..<at])
            )
        }
        if let profile = target {
            workspace.open(profile)
            if let sql = environment["SQPRO_SQL"], let tab = workspace.selectedTab {
                for _ in 0..<50 where !isConnected(tab) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                tab.selectedQuery?.text = sql
                tab.run(.all)
                if environment["SQPRO_DEMO_EDITS"] != nil {
                    for _ in 0..<50 where tab.selectedQuery?.selectedResult?.isEditable != true {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if let result = tab.selectedQuery?.selectedResult, let column = result.editTarget?.editableColumns.max() {
                        result.setValue(environment["SQPRO_DEMO_VALUE"] ?? "edited value", atVisibleRow: 0, column: column)
                        if result.visibleRows.count > 1 { result.deleteRows([1]) }
                        if let row = result.insertRow(), let first = result.firstEditableColumn {
                            result.setValue("new", atVisibleRow: row, column: first)
                        }
                        // SQPRO_DEMO_EDITS=fail also sets the first editable column to NULL, to test rollback
                        // on a NOT NULL column.
                        if environment["SQPRO_DEMO_EDITS"] == "fail", let first = result.firstEditableColumn {
                            result.setValue(nil, atVisibleRow: 0, column: first)
                        }
                        // SQPRO_APPLY=1: run Apply and print the script and the outcome.
                        if environment["SQPRO_APPLY"] != nil, let document = tab.selectedQuery {
                            for _ in 0..<50 where tab.isRunning {
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                            let script = result.changeScript()
                            print("SCRIPT:\n\(script)")
                            let failure = await tab.applyChanges(script, to: result, in: document)
                            print("OUTCOME: \(failure ?? "applied")")
                            print("AFTER: \(document.selectedResult?.result.rows ?? [])")
                            print("CHANGES LEFT: \(document.selectedResult?.hasChanges ?? false)")
                        }
                    }
                }
            }
            if let sql = environment["SQPRO_DROP_SQL"], let tab = workspace.selectedTab {
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<50 where tab.isRunning || !isConnected(tab) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await tab.debugDropQueryConnection()
                tab.selectedQuery?.text = sql
                tab.run(.all)
                try? await Task.sleep(for: .milliseconds(300))
                for _ in 0..<50 where tab.isRunning || tab.log.last?.status == .running {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                print("LOG: \(tab.log.map { "\($0.action) => \($0.response)" })")
            }
            if environment["SQPRO_BOTTOM"] == "ai" { workspace.selectedTab?.bottomPanel = .aiActivity }
            if environment["SQPRO_BOTTOM"] == "history" { workspace.selectedTab?.bottomPanel = .history }
            if let spec = environment["SQPRO_IMPORT"], let tab = workspace.selectedTab, let colon = spec.firstIndex(of: ":") {
                for _ in 0..<50 where !isConnected(tab) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let parts = spec[..<colon].split(separator: ".").map(String.init)
                let url = URL(fileURLWithPath: String(spec[spec.index(after: colon)...]))
                if parts.count == 2, let schema = tab.schemaNode(parts[0]) {
                    await tab.loadObjects(of: schema)
                    if let table = tab.tableNode(parts[0], parts[1]) {
                        await tab.openImport(of: url, into: table, in: schema)
                        if let mode = environment["SQPRO_IMPORT_DUPLICATES"].flatMap(CSVImportPlan.Duplicates.init(rawValue:)) {
                            tab.importJob?.duplicates = mode
                        }
                        if environment["SQPRO_IMPORT_RUN"] != nil, let job = tab.importJob {
                            print("MAPPING: \(zip(job.headers, job.mapping.map { $0.map { job.columns[$0].name } ?? "skip" }).map { "\($0) -> \($1)" })")
                            await tab.runImport(job)
                            print("IMPORT: \(job.phase)")
                        }
                    }
                }
            }
            if let target = environment["SQPRO_TABLE_INFO"], let tab = workspace.selectedTab {
                for _ in 0..<50 where !isConnected(tab) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let parts = target.split(separator: ".").map(String.init)
                if parts.count == 2, let schema = tab.schemaNode(parts[0]) {
                    await tab.loadObjects(of: schema)
                    if let table = tab.tableNode(parts[0], parts[1]) {
                        tab.openTableInfo(table, in: schema)
                        if let section = environment["SQPRO_TABLE_SECTION"].flatMap(TableInfo.Section.init(rawValue:)) {
                            tab.selectedQuery?.tableInfo?.section = section
                        }
                    }
                }
            }
        }
        if let typed = environment["SQPRO_TYPE"], let tab = workspace.selectedTab {
            for _ in 0..<50 where !isConnected(tab) || tab.selectedQuery?.editor == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(500))
            if let editor = tab.selectedQuery?.editor {
                NSApp.activate()
                editor.window?.makeKeyAndOrderFront(nil)
                editor.window?.makeFirstResponder(editor)
                for character in typed {
                    editor.insertText(String(character), replacementRange: editor.selectedRange())
                }
                try? await Task.sleep(for: .seconds(1))
                print("COMPLETIONS: \(editor.debugCompletionNames.prefix(15))")
            }
        }
        if let mode = environment["SQPRO_SAVED_QUERIES"], let tab = workspace.selectedTab {
            try? await Task.sleep(for: .seconds(1))
            tab.savesNewQuery = mode == "save"
            tab.showsSavedQueries = true
        }
        guard let path = environment["SQPRO_SNAPSHOT"] else { return }
        let delay = Double(environment["SQPRO_SNAPSHOT_DELAY"] ?? "") ?? 4
        try? await Task.sleep(for: .seconds(delay))
        save(to: URL(fileURLWithPath: path))
        // An open sheet blocks quitting.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
        try? await Task.sleep(for: .seconds(2))
        exit(0)
    }

    private static func isConnected(_ tab: ConnectionTab) -> Bool {
        if case .connected = tab.state { return true }
        return false
    }

    @MainActor
    private static func save(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let main = windows.first(where: { $0.title == "Querywell" }) ?? windows.first else { return }
        write(main, to: url)
        for (index, window) in windows.filter({ $0 !== main }).enumerated() {
            let name = url.deletingPathExtension().lastPathComponent + "-\(index + 1)." + url.pathExtension
            write(window, to: url.deletingLastPathComponent().appending(path: name))
        }
    }

    @MainActor
    private static func write(_ window: NSWindow, to url: URL) {
        // cacheDisplay can't draw glass; draw what's inside it instead.
        let glassContent = (window.contentView as? NSGlassEffectView)?.contentView
        guard let view = glassContent ?? window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
