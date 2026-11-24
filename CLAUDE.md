# Query Pro

Native macOS MySQL and Redis client (macOS 26+, Liquid Glass). Workbench-style layout, only the features we use.
`SPEC.md` is the product spec and build order; keep its ✅ list current.

## Build and run

```
scripts/bundle.sh --debug --open   # build dist/Query Pro.app, quit the running copy, launch it
scripts/bundle.sh --sign "Apple Development: haolun"   # release build signed with the personal identity
swift test                         # SQCore + SQMCP tests (SQL parsing, autocomplete, export, Keychain, MCP tools)
SQPRO_REDIS=127.0.0.1:6390 SQPRO_REDIS_PASSWORD=… swift test   # also the live Redis tests (skipped otherwise); see Gotchas
.build/debug/sqcheck localhost 3306 root "" "select 1"   # CLI connection check; password from SQ_PASSWORD, SQ_SSL=disabled for no TLS
```

Plain SwiftPM, no Xcode project. The app is ad-hoc signed by `bundle.sh` unless `--sign` names a Keychain identity.
`swift scripts/make-icon.swift` rebuilds `Resources/AppIcon.icns` from `Resources/AppIcon-source.png` (agy-generated).

The app was renamed from "SQ Pro" to "Querywell" and then to **Query Pro**, but only the visible name changed. Module/target names (`SQPro`),
the executable, bundle id `app.sqpro.SQPro`, Keychain service `app.sqpro.password`, `Application Support/SQPro`,
UserDefaults keys and `SQPRO_*` env vars stay as they are: renaming them would orphan saved connections and passwords.

## Layout

| Path | What |
|---|---|
| `Sources/SQCore` | No UI. `MySQLSession` (actor, mysql-nio), `TextQueryCommand`, `SQL` (tokenizer, statement splitter, auto `LIMIT`, beautify, quoting), `SQLCompletion` (autocomplete context + suggestions), `SQLAutoCorrect` (keyword typos), `SchemaScript` (Alter / Drop Schemas, Drop / Truncate Tables SQL), `SQLDump`/`SQLDumpImport`/`SQLDumpExport` (`.sql` dumps), `ResultExport` (CSV/JSON/INSERT), `CSV`/`CSVImportPlan` (import), `QueryHistoryStore`, `SavedQuery`/`SavedQueryStore`, `ConnectionProfile`/`ConnectionStore`, `Keychain`, `ErrorText`. Redis: `RESP` (protocol), `RedisSession` (actor, NIO), `RedisCommand` (console parsing, redis-cli output, AI access rules), `RedisBrowser` (SCAN, values, key tree) |
| `Sources/SQMCP` | No UI. `MCPHTTPServer` (NIO HTTP on 127.0.0.1, one endpoint per connection at `/mcp/<connection id>` with its own bearer token, one MCP session per client, adapted from swift-sdk's conformance server) and `SQLTools` (ten tools scoped to one connection) or `RedisTools` (six, for Redis connections). Talks to the app through `MCPProvider` |
| `Sources/SQPro/App` | `SQProApp`, `Workspace` (tabs), `ConnectionsModel` (saved connections), `SavedQueriesModel`, `TabStrip`, `QueryCommands` (menus + shortcuts), `SettingsView`, `DebugSnapshot` |
| `Sources/SQPro/Home` | Home screen: connection cards, groups, add/edit form |
| `Sources/SQPro/Connection` | `ConnectionTab` (model for one open connection), schema sidebar, query area, table info tab, Action Output, History, CSV import sheet |
| `Sources/SQPro/Editor` | `SQLTextView` (TextKit 1), `CompletionPopup` (autocomplete list), line number ruler, theme, SwiftUI wrappers |
| `Sources/SQPro/Redis` | `RedisTab` (model: two sessions, keys, value, console), key sidebar, value editors, console, New Key sheet |
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
- The schema tree selects several objects (`sidebarSelection` is a `Set`); use `selectedObject` for "the one selected
  thing". Alter / Drop Schemas build SQL in `SchemaScript` (SQCore) and run through `runSchemaScript`.
- Schema tree rows need `.listRowSeparator(.hidden)`; double-click goes through `.contextMenu(forSelectionType:primaryAction:)`, not `onTapGesture(count: 2)` (the List swallows it).
- Each connection tab has **two sessions**: one for user queries, one for metadata (schema tree, table info), so a slow query never blocks the sidebar. Stop sends `KILL QUERY` from a third, short-lived connection.
- Shortcuts are menu items in `QueryCommands`, so they work while the NSTextView has focus.
- **Remote = red editor**: `ConnectionProfile.isRemote` (not `LocalMySQLServer.isLocal(host:)`) makes `SQLEditor` use
  `SQLTheme.remoteBackground`; the ruler fills with the text view's background, so it follows. To see it locally, open
  `SQPRO_OPEN_TEMP=root@0.0.0.0:3306`: it reaches local MySQL but isn't a local host name.
- **mysql-nio ≥ 1.9.3**: older versions keep the handshake nonce's trailing NUL, so `caching_sha2_password` logins
  without TLS fail for passwords of 20+ characters (MySQL 8 and 9). MySQL 9's `VECTOR` (type 0xF2) has no name in
  mysql-nio; `MySQLSession` names it and treats it as binary. To test 9.x: `brew install mysql@9.7` (keg-only), then
  run `mysqld --no-defaults --initialize-insecure` and `mysqld --no-defaults` with a scratch datadir, another port and
  a short `--socket` path (macOS limit is 103 characters).
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
- **Autocomplete**: `SQLCompletion` (SQCore, unit-tested) does all parsing; `CompletionController` is only the
  window. The list is a child `NSPanel` that never becomes key, so the text view keeps focus and forwards ↑↓/Return/
  Tab/Esc through `doCommand(by:)`. Any change to its `items` must reload the table at once (it lays out even while
  hidden and would index past the end). `ConnectionTab` is the `CompletionSource`: it loads one schema's tables and
  columns at a time on `metaSession`, and every waiting editor is called back when loading finishes.
- **Keyword autocorrect**: `SQLAutoCorrect` (SQCore, unit-tested) holds the typo list and context rules;
  `SQLTextView` applies a fix after a word-ending key, as its own undo step. A new typo must be ≥ 4 letters, not a
  keyword and not a likely name (`SQLAutoCorrectTests.listIsSafe` checks the first two). Real words like `form` need
  a context rule, not `.anywhere`.
- **Reconnect** lives in `MySQLSession` (actor): `reviveIfNeeded` pings after 30 s idle (closing the channel after
  5 s so a dead socket can't hang), `isConnectionLost` classifies errors, `SQL.useTarget` + `remember(database:)` keep
  the schema, and the OK packet's `SERVER_STATUS_IN_TRANS` decides whether a drop must be reported
  (`SessionError.lostTransaction`). Only read-only statements are retried. `ReconnectTests` drop the connection with
  `KILL` against local MySQL.
- **History** is JSON Lines, appended per statement (`ConnectionTab.recordHistory`), loaded only when the panel opens.
  Always pass SQL through `QueryHistoryStore.redacted` first.
- **Drop / Truncate Tables** (`TableChangeSheet`) run `SchemaScript.dropTables` / `truncateTables` through
  `ConnectionTab.runTableScript`: query session, between `SET FOREIGN_KEY_CHECKS = 0 / 1`, and it turns checks back on
  if a statement in between fails. Progress goes to the sheet; dialogs (drop/truncate, imports, export) never write
  to Action Output, only one History entry. MCP `drop_tables` / `truncate_tables` use the same SQL.
- **SQL dump import**: `SQLDump.statements` has its own splitter (not `SQL.statements`): it follows `DELIMITER` lines
  and keeps `/*! … */` executable comments as code. `SQLDump.plan(mode:)` filters for data only; `SQLDumpImport.run`
  is shared by the app (`SQLImportSheet`, fresh session) and MCP `import_sql`. Data only = one transaction; tables and
  data stops at the first error. MCP `import_sql` / `export_sql` only take absolute `.sql` paths.
- **SQL dump export** (`SQLDumpExport`, shared by `SQLExportSheet` and MCP `export_sql`) must stay importable by
  `SQLDump` and the `mysql` client; `SQLDumpExportTests.roundTrip` exports, re-imports into another schema and
  compares `CHECKSUM TABLE`. It `USE`s the schema first so SHOW CREATE leaves names unqualified.
- **CSV import** runs on a fresh `MySQLSession` (the tab keeps its password in memory for this), never the query
  session, so the editor stays usable. `CSV.parse` returns `nil` for unquoted empty / `\N` fields so NULL and ''
  survive a round trip with `ResultExport.csv`.
- **Redis**: `ConnectionProfile.kind` (`.mysql` default, so old files load) picks `ConnectionTab` or `RedisTab` in
  `Workspace.open`, and `SQLTools` or `RedisTools` in `MCPController`. Both tabs are `WorkspaceTab`; `selectedTab` is
  the MySQL one, so menu commands ignore Redis tabs. `ForEach` over `[any WorkspaceTab]` needs the `TabRef` wrapper: a
  key path on the existential crashes the Swift 6.4 compiler. Redis TLS is `SSLMode.required` (no negotiation); the
  form's toggle maps to it. Values are `Data` everywhere (Redis is binary-safe): show them with
  `RedisCommand.display`, and keep binary values read-only in the editors. `RedisCommand.access` decides what AI may
  run; unknown commands count as writes. The browser session's `SELECT` is the picker's; the console has its own
  session and database. `RedisSession.close()` makes a waiting command fail without reconnecting (console Stop).
  Live tests: run `redis-server` (Homebrew) on a spare port with `user default on >pass ~* &* +@all`, a
  `tls-port` with a self-signed cert, and a read-only ACL user; set `SQPRO_REDIS`, `SQPRO_REDIS_PASSWORD`,
  `SQPRO_REDIS_TLS_PORT`, `SQPRO_REDIS_ACL_USER`, `SQPRO_REDIS_ACL_PASSWORD`. Tests only write `qp:test:*` / `qp:mcp:*`.
  Snapshots: `SQPRO_OPEN_TEMP=redis://[user@]host:port` + `SQPRO_REDIS_PASSWORD`, `SQPRO_REDIS_TLS=1`,
  `SQPRO_REDIS_KEY`, `SQPRO_REDIS_COMMAND` ("a ;; b"), `SQPRO_REDIS_EDIT=new`, `SQPRO_NEW_CONNECTION=redis`.
- **Local server** (`LocalMySQLServer`, SQCore): status is a TCP connect to 127.0.0.1:3306, then `launchctl print`
  (no root). Start/Stop run `launchctl kickstart` / `kill TERM` on Oracle's system LaunchDaemon through
  `osascript … with administrator privileges`; never sudo. `LocalServerController` is shared by the home header
  button and the "Can't connect" view.
- `sqcheck` prompts for a password on a TTY-less stdin unless `SQ_PASSWORD` is set: use `SQ_PASSWORD="" … </dev/null`.
- MySQL 8 reserves words like `empty`; a 1064 error from a test query may be the query, not the app.
- Non-root users don't see `information_schema`, `performance_schema`, `mysql`, `sys` in the sidebar.

## Seeing the UI

There is no Screen Recording permission, so `screencapture` fails. Use the debug-only hook in `DebugSnapshot.swift`:

```
SQPRO_OPEN="Local POS" SQPRO_SQL="select * from pos.admins limit 5;" \
SQPRO_SNAPSHOT=/path/out.png "dist/Query Pro.app/Contents/MacOS/SQPro"
```

Also `SQPRO_OPEN_TEMP=root@localhost:3306` (throwaway connection, never saved), `SQPRO_TABLE_INFO=schema.table`,
`SQPRO_TABLE_SECTION=Indexes`, `SQPRO_DEMO_EDITS=1` (in-memory edits, never applied), `SQPRO_SNAPSHOT_DELAY=4`,
`SQPRO_TYPE="select * from ad"` (types key by key, `⌫` is Backspace; prints the text and the autocomplete list),
`SQPRO_SAVED_QUERIES=1|save`, `SQPRO_BOTTOM=history`, `SQPRO_SCHEMAS=drop:a,b` (select schemas, open the Drop /
`alter:` sheet; `SQPRO_SCHEMAS_RUN=1` runs it, scratch databases only), `SQPRO_DROP_SQL` (kill the query connection,
then run SQL: tests reconnect),
`SQPRO_IMPORT=schema.table:/file.csv` (+ `SQPRO_IMPORT_RUN=1`, `SQPRO_IMPORT_DUPLICATES=skip`; scratch databases only),
`SQPRO_TABLES=drop:schema` / `truncate:schema.a,b` (+ `SQPRO_TABLES_RUN=1`), `SQPRO_DUMP=schema:/file.sql`
(+ `SQPRO_DUMP_MODE=data_only`, `SQPRO_DUMP_RUN=1`), `SQPRO_EXPORT=schema` (sheet) or `schema:/out.sql` (runs;
`SQPRO_EXPORT_CONTENT=data_only`); all scratch databases only.
Temp connections write history files under a random id; delete them after testing.
Other windows (popovers, the autocomplete list) are saved next to it as `out-1.png` …. The capture uses
`cacheDisplay`, so glass, translucent materials and list separators don't appear as on screen. Don't `pkill` the
test copy by path: it also kills the user's running app; let `SQPRO_SNAPSHOT` quit it.

Data: connections in `~/Library/Application Support/SQPro/connections.json`, passwords in the login keychain under
service `app.sqpro.password`, account = profile id.
