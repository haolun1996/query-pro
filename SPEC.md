# SQ Pro — spec

A native macOS MySQL client. Workbench-style layout, Liquid Glass look, only the features we use.

- **Platform:** macOS 26+ only (Liquid Glass). No Windows, no iOS.
- **Database:** MySQL only.
- **Stack:** SwiftUI shell, AppKit `NSTableView` for result grids, `MySQLNIO` driver (in `SQCore`).
- **Out of scope:** SSH tunnel, AI chat, plugins, other databases, Workbench import.

## Layout

Plain SwiftPM, no Xcode project (same setup as code-planet).

```
Package.swift
Sources/
  SQCore/    profiles, Keychain, MySQL session, query results (no UI)
  SQPro/     the app: App/, Home/, Connection/
  sqcheck/   CLI connection check: sqcheck <host> <port> <user> [schema] [sql]
Tests/SQCoreTests/
Resources/Info.plist
scripts/bundle.sh   → dist/SQ Pro.app (ad-hoc signed)
```

```
scripts/bundle.sh --debug --open   # build, quit the running copy, launch
swift test
```

Connections are saved to `~/Library/Application Support/SQPro/connections.json`.
Passwords are in the login keychain (service `app.sqpro.password`, account = profile id), always through
`/usr/bin/security`, never Security.framework: the app is ad-hoc signed, so its signature changes every
build and framework access would prompt again each time. Items created by `security` never prompt.

## 1. Home screen
- Glass cards: name, user, `host:port`. Tint from the connection colour; red = production.
- Group folders (blue) show "N Connections". Inside a group, a red **< back** card comes first (Esc also goes back).
- Search box filters across all groups.
- Click a card to open the connection in its own window.
- Right-click a connection: Open, Edit, Duplicate, Move to Group (incl. New Group / Remove from Group), Delete.
- Right-click a group: Open, Rename, Ungroup.
- Drag a card onto a folder to move it; onto **< back** to take it out of the group.

## 2. Groups
One level only. A group exists while at least one connection is in it.

## 3. Connection window
- Glass sidebar on the left: schema tree (Tables, Views, Stored Procedures, Functions) with a filter box, Object Info panel at the bottom.
- Query editor on the right with tabs.
- Toolbar: Run all, Run current, Stop, row limit, Beautify, Find, Invisibles, Wrap.
- Statement under the cursor is highlighted.

| Key | Action |
|---|---|
| ⌘T | New query tab |
| ⌘W | Close tab |
| ⌘↩ | Run selection, or the statement under the cursor |
| ⇧⌘↩ | Run everything |
| ⌘. | Stop running query (`KILL QUERY` on a second connection) |
| ⌘B | Beautify SQL |
| ⌘O | Open `.sql` file |
| ⌘S | Save query to `.sql` |
| ⌘F | Find |

## 4. Results
- Row limit dropdown: Don't Limit, 10, 50, 100, 200, 300, 400, 500, 1000, 2000, 5000, 10000, 50000. Default 1000, remembered per connection. Adds `LIMIT n` only when the query has none. Status shows "(limited)".
- Result grid toolbar: Filter Rows, Edit (edit / add row / delete row), Export.
- One result tab per result set (e.g. `customer_points 1`).
- NULL shown as a badge.
- Right-side tabs: Result Grid, Form Editor, Field Types, Query Stats.
- Action Output panel: status, time, SQL, response ("3 row(s) returned" / error), duration.

## 5. Editing
- Only for results from one table with a primary key; otherwise read-only with a note.
- Edited cells blue, new rows green, deleted rows red with strikethrough.
- Apply / Revert enabled only while there are pending changes. ⌘Z undoes one change.

## 6. Apply dialog
- Sheet with the generated SQL, syntax highlighted and editable. Buttons: Go Back, Apply.
- Numbers unquoted, real `NULL`.
- All statements run in one transaction; on error everything rolls back and edits stay pending.
- Red connections: Apply is red and asks once more.

## 7. MCP server
- Runs inside the app on `127.0.0.1` (HTTP transport), toggle in Settings, bearer token.
- Tools: `list_connections` (no passwords), `list_databases`, `list_tables`, `describe_table`, `run_query` (SELECT), `execute` (writes, only if allowed).
- Read-only by default per connection. Writes on red connections need confirmation in the app.
- Results capped (e.g. 500 rows). AI activity log panel.

## Phase 2
Autocomplete, export (CSV / JSON / SQL INSERT), saved queries.

## Build order
1. ✅ Driver check (`sqcheck`)
2. ✅ Home screen, groups, add/edit connection, Keychain
3. ✅ Connection tab: schema sidebar, query tabs, editor, shortcuts, Action Output
4. ✅ Result grid, result tabs, Form Editor / Field Types / Query Stats
5. ✅ Editing, Apply/Revert, confirm dialog
6. ✅ MCP server
7. Phase 2
