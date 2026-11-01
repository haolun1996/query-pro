# SQ Pro

Native macOS MySQL client (macOS 26+, Liquid Glass). Workbench-style layout, only the features we use.
`SPEC.md` is the product spec and build order; keep its ✅ list current.

## Build and run

```
scripts/bundle.sh --debug --open   # build dist/SQ Pro.app, quit the running copy, launch it
swift test                         # SQCore tests (SQL parsing, Keychain round trip)
.build/debug/sqcheck localhost 3306 root "" "select 1"   # CLI connection check; password from SQ_PASSWORD
```

Plain SwiftPM, no Xcode project. The app is ad-hoc signed by `bundle.sh`.

## Layout

| Path | What |
|---|---|
| `Sources/SQCore` | No UI. `MySQLSession` (actor, mysql-nio), `TextQueryCommand`, `SQL` (tokenizer, statement splitter, auto `LIMIT`, beautify, quoting), `ConnectionProfile`/`ConnectionStore`, `Keychain`, `ErrorText` |
| `Sources/SQMCP` | No UI. `MCPHTTPServer` (NIO HTTP on 127.0.0.1, one endpoint per connection at `/mcp/<connection id>` with its own bearer token, one MCP session per client, adapted from swift-sdk's conformance server) and `SQLTools` (six tools scoped to one connection). Talks to the app through `MCPProvider` |
| `Sources/SQPro/App` | `SQProApp`, `Workspace` (tabs), `ConnectionsModel` (saved connections), `TabStrip`, `QueryCommands` (menus + shortcuts), `SettingsView`, `DebugSnapshot` |
| `Sources/SQPro/Home` | Home screen: connection cards, groups, add/edit form |
| `Sources/SQPro/Connection` | `ConnectionTab` (model for one open connection), schema sidebar, query area, table info tab, Action Output |
| `Sources/SQPro/Editor` | `SQLTextView` (TextKit 1), line number ruler, theme, SwiftUI wrappers |
| `Sources/SQPro/Results` | `ResultTab` (one result set + filter/sort/edits), `ResultGrid` (NSTableView), results panel, Form Editor / Field Types / Query Stats |

## Conventions

- 4-space indentation, ~140 columns. If you run `swift format`, pass a config with `"indentation": {"spaces": 4}`; its default is 2.
- The app target uses MainActor default isolation. SQCore does not.
- State lives in `@Observable` models (`Workspace`, `ConnectionTab`, `QueryDocument`, `ResultTab`), not in views, so switching tabs never loses work.
- Comments explain why, not what. Match the surrounding style.

## Gotchas

- **Keychain only through `/usr/bin/security`** (`Keychain.swift`), never Security.framework. The app is ad-hoc signed, its signature changes every build, and framework access would prompt after each rebuild. Read with `-g` (stderr), not `-w`: `-w` hex-encodes non-ASCII passwords ambiguously.
- **No `HSplitView` / `NavigationSplitView` / `.listStyle(.sidebar)`** in the main window: they stretch into the hidden title bar and cover the tab strip. Use `SidebarSplit` / `VerticalSplit`.
- `VerticalSplit(showsBottom:)` hides a pane without changing the top view's identity; the SQL editor must not be rebuilt when results appear.
- Schema tree rows need `.listRowSeparator(.hidden)`; double-click goes through `.contextMenu(forSelectionType:primaryAction:)`, not `onTapGesture(count: 2)` (the List swallows it).
- Each connection tab has **two sessions**: one for user queries, one for metadata (schema tree, table info), so a slow query never blocks the sidebar. Stop sends `KILL QUERY` from a third, short-lived connection.
- Shortcuts are menu items in `QueryCommands`, so they work while the NSTextView has focus.
- The grid's text is single-line; values over 500 characters are cut for display only.
- **Editing results**: `ConnectionTab.prepareEditing` makes a result editable only when its table columns come from one
  table and include its whole primary key. Edits are overlays (`RowEdits`) on the original rows; `ChangeScript`
  (SQCore, unit-tested) turns them into SQL that finds rows by their *original* key values. Apply runs the script in
  one transaction, rolls back on any error, then re-runs the result's SQL.
- **MCP safety**: `run_query` must pass `SQL.isReadOnly` (one statement, no INTO/FOR UPDATE/writes) *and* runs inside
  `START TRANSACTION READ ONLY` with `MAX_EXECUTION_TIME`. `execute` needs `mcpAccess == .readWrite`; red connections
  call `MCPProvider.approveWrite` (an NSAlert, Deny is default). Every tool call opens its own MySQL connection.
  A connection may set `mcpUser` (separate MySQL login for AI, password under `Keychain.Kind.mcp`); `SQLTools.asAI`
  swaps it in for every tool call, so MySQL grants limit the AI. `SQPRO_REQUIRE_MYSQL=1 swift test` makes the
  local-MySQL login tests fail instead of skip when the server is down.
  Each connection is its own MCP server: tokens live in UserDefaults `mcpTokens` (connection id → token), created on
  first "Copy Claude Code Command"; a token only opens its own `/mcp/<id>`. The command has no `--scope`, so Claude
  Code adds it to the project it's run in. Per-connection MCP UI lives in each connection tab (`MCPConnectionButton`
  popover, and the bottom panel's AI Activity view); Settings only has the server switch and port.
  `MCPActivity.connectionID` drives those filters.
  Test with curl: initialize → read `Mcp-Session-Id` → `notifications/initialized` → `tools/call`; responses are SSE.
- MySQL 8 reserves words like `empty`; a 1064 error from a test query may be the query, not the app.
- Non-root users don't see `information_schema`, `performance_schema`, `mysql`, `sys` in the sidebar.

## Seeing the UI

There is no Screen Recording permission, so `screencapture` fails. Use the debug-only hook in `DebugSnapshot.swift`:

```
SQPRO_OPEN="Local POS" SQPRO_SQL="select * from pos.admins limit 5;" \
SQPRO_SNAPSHOT=/path/out.png "dist/SQ Pro.app/Contents/MacOS/SQPro"
```

Also `SQPRO_OPEN_TEMP=root@localhost:3306` (throwaway connection, never saved), `SQPRO_TABLE_INFO=schema.table`,
`SQPRO_TABLE_SECTION=Indexes`, `SQPRO_DEMO_EDITS=1` (in-memory edits, never applied), `SQPRO_SNAPSHOT_DELAY=4`. The capture uses `cacheDisplay`, so translucent materials
and list separators may not appear exactly as on screen.

Data: connections in `~/Library/Application Support/SQPro/connections.json`, passwords in the login keychain under
service `app.sqpro.password`, account = profile id.
