# Query Pro

A native macOS MySQL client with a Workbench-style layout and the Liquid Glass look. It covers the features
we use every day and nothing more.

- **macOS 26+ only**, MySQL only
- SwiftUI shell, AppKit `NSTableView` result grids, [MySQLNIO](https://github.com/vapor/mysql-nio) driver
- Built-in MCP server, so Claude Code (or any MCP client) can query a connection you allow

## Features

- **Home screen**: connection cards with colours (red = production), one level of groups, search, drag and drop.
- **Query editor**: tabs, highlighting of the statement under the cursor, autocomplete for tables, columns, aliases,
  schemas, keywords and functions, beautify, find, open and save `.sql` files.
- **Schema sidebar**: tables, views, stored procedures and functions, plus a table info tab (columns, indexes, …).
  Metadata loads on its own connection, so a slow query never blocks it.
- **Results**: one tab per result set, an automatic row limit, filter and sort, Form Editor, Field Types and Query
  Stats. Export to CSV, JSON or SQL `INSERT`, to a file or the clipboard.
- **Editing**: for results from one table with a primary key. Edit, add or delete rows, then review the generated
  SQL and apply it in a single transaction that rolls back on any error.
- **Saved queries and history**: bookmark queries per connection or for all of them. History is searchable and
  kept across launches, with passwords masked.
- **CSV import**: auto-detects the delimiter and maps columns by name. Duplicate rows can stop the import, be
  skipped or be replaced. Runs in one transaction with progress and Stop.
- **Reconnect**: dropped connections come back by themselves. Read-only statements are retried once, and a
  connection lost inside a transaction is reported, never silently replaced.
- **Stop** (⌘.) sends `KILL QUERY` from a separate connection.

## Keyboard shortcuts

| Key | Action |
|---|---|
| ⌘T / ⌘W | New / close query tab |
| ⌘↩ | Run selection, or the statement under the cursor |
| ⇧⌘↩ | Run everything |
| ⌘. | Stop the running query |
| ⌘B | Beautify SQL |
| ⌘F | Find |
| ⌘O / ⌘S | Open / save `.sql` file |
| ⌥⌘O / ⌥⌘S | Saved queries / save query |
| ⌘Y | Query history |

## Build and run

Requires macOS 26 and a Swift 6.2 toolchain (Xcode 26). Plain SwiftPM, no Xcode project.

```sh
scripts/bundle.sh --debug --open   # build dist/Query Pro.app (ad-hoc signed), quit the running copy, launch it
scripts/bundle.sh                  # release build
swift test                         # SQCore + SQMCP tests
```

`sqcheck` is a small CLI for checking a connection (it takes the password from `SQ_PASSWORD`):

```sh
swift build --product sqcheck
SQ_PASSWORD="" .build/debug/sqcheck localhost 3306 root "" "select 1"
```

## AI access (MCP)

Turn on the server in **Settings**. It listens on `127.0.0.1:7531` by default. Each connection is its own MCP
server, at `/mcp/<connection id>` with its own bearer token, and is hidden from AI until you allow it under
**Edit Connection › AI access**:

- **Read only**: `run_query` accepts a single read-only statement and runs it inside `START TRANSACTION READ ONLY`
  with a time limit.
- **Read & write**: `execute` is also allowed. On red (production) connections, every write has to be approved
  in the app.
- Optionally use a separate MySQL user for AI, so MySQL grants limit what it can touch.

Tools: `connection_info`, `list_databases`, `list_tables`, `describe_table`, `run_query`, `execute`.

To connect Claude Code, use **Copy Claude Code Command** (in a connection tab's MCP button, or right-click a
connection on the home screen) and run it in your project folder:

```sh
claude mcp add --transport http query-pro-<connection> http://127.0.0.1:7531/mcp/<id> --header "Authorization: Bearer <token>"
```

The AI Activity view in the bottom panel lists every tool call for that connection.

## Where data lives

| What | Where |
|---|---|
| Connections | `~/Library/Application Support/SQPro/connections.json` |
| Passwords | Login keychain, service `app.sqpro.password` (account = connection id) |
| Saved queries | `~/Library/Application Support/SQPro/saved-queries.json` |
| History | `~/Library/Application Support/SQPro/history/<connection id>.jsonl` |

Passwords are read and written only through `/usr/bin/security`. The app is ad-hoc signed and its signature changes
with every build, so Security.framework would ask for keychain access again after each rebuild.

The app used to be called SQ Pro, which is why internal names (`SQPro`, bundle id `app.sqpro.SQPro`) still use it.

## Project layout

| Path | What |
|---|---|
| `Sources/SQCore` | No UI: MySQL session, SQL tokenizer and helpers, autocomplete, export, CSV import, stores, Keychain |
| `Sources/SQMCP` | No UI: the MCP HTTP server and its SQL tools |
| `Sources/SQPro` | The app: home screen, connection tabs, editor, result grid |
| `Sources/sqcheck` | CLI connection check |
| `Tests` | SQCore and SQMCP tests |
| `SPEC.md` | Product spec and build order |
