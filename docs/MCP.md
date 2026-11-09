# RAMNest stdio MCP

`RAMNestMCP` is the SwiftPM executable target; its product is `ramnest-mcp`.
It is macOS only, with the same macOS 27 minimum as RAMNest. It reuses
`RAMNestCore`; it does not implement a filesystem or elevated mount API.

There is no `.specify/feature.json` in this checkout. The requested MCP contract,
the current app controls below, and `SECURITY.md` govern this additive change.
Existing metadata/recovery edits were retained. No user store, mount, preference,
login item, or installed application is used by the automated tests.

## Build and connect

Released upstream versions were discovered on 2026-11-09 and pinned exactly:

| Package | Release | Source |
| --- | --- | --- |
| Official Model Context Protocol Swift SDK | 0.12.1 | [upstream releases](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1) |
| swift-log | 1.17.0 | [upstream release](https://github.com/apple/swift-log/releases/tag/1.17.0) |
| swift-service-lifecycle | 2.13.0 | [upstream release](https://github.com/swift-server/swift-service-lifecycle/releases/tag/2.13.0) |

The adapter uses the SDK's `Server`, `StdioTransport`, `withMethodHandler`,
`start(transport:)`, `waitUntilCompleted()` and `stop()` APIs. It does not use
old `Params` aliases or fabricated lifecycle APIs. `ServiceGroupConfiguration`
selects graceful group termination on normal EOF. `StreamLogHandler.standardError`
is the sole logging backend. Standard output carries newline-delimited MCP
JSON-RPC only, including errors. Core child CLI output is captured privately.

From the repository:

```sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/mcp-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox -c release --product ramnest-mcp
swift test --disable-sandbox --filter ActivitiesTests
bash scripts/package.sh --output "$PWD/artifacts/mcp-package-$(date +%Y%m%d-%H%M%S)"
```

The SwiftPM build plugin finalizes/signs a native helper, then generates its
compiled Core authority before compilation. `--disable-sandbox` here disables
SwiftPM's nested build-script sandbox so that the existing CMake/codesign build
can run; it does not bypass RAMNest runtime helper authorization. No source
contains a default helper hash or runtime authority override.

Packaging embeds the server at
`RAMNest.app/Contents/Helpers/ramnest-mcp`, signs that exact executable, then
reseals and verifies the app. The embedded native CLI and helper remain the pair
built by `scripts/build.sh`; the MCP server never substitutes its independently
built helper. A source archive includes `Plugins/` as well as `Sources/`.

Example MCP client configuration after successful packaging:

```json
{
  "mcpServers": {
    "ramnest": {
      "command": "/absolute/path/RAMNest.app/Contents/Helpers/ramnest-mcp"
    }
  }
}
```

A standalone server can select a package explicitly with
`--app /absolute/path/RAMNest.app`. This is a process-start option, never a tool
argument. `--store /absolute/bootstrap` selects an isolated, selection-aware
storage bootstrap; omitting it uses RAMNest's Application Support bootstrap.
Paths must be absolute, standardized and accepted by Core's no-symlink policy.
Use an owned directory on a data volume for fixtures: Foundation can rewrite
existing `/private/tmp` paths to `/tmp`, which Core correctly rejects as a
symlink path. Never point acceptance tests at the default user store.

Startup constructs no Engine/Store until a data tool is called. It does not
mount, recover, reconnect, schedule startup folders, or launch the GUI. EOF,
SIGINT and SIGTERM close the transport, cancel outstanding recovery reviews,
request precommit storage pause and await that worker. They never eject a
folder. An admitted native operation is allowed to finish or reach its bounded
CLI timeout before shutdown; the persistent ordinary-user mount pin belongs to
the mounted folder, not the MCP session.

## Authority, validation and results

`capabilities` reports the fixed `tmpfs` backend, unsupported removed controls,
package availability/reason and the packaged CLI's compiled build identity.
Static package checks are prerequisites; they do not claim a successful mount
or administrator authorization. Without a valid selected package, ordinary
configuration, disk checkpoint export and legacy disk recovery remain available;
native lifecycle and login-item operations return explicit errors.

Native mount/reconnect/save/eject, native recovery/live export, active delete
and active RESET invoke only `Contents/Helpers/ramnest` with allowlisted generated
arguments. That CLI executes the original Core path, validating its own running
code, sealed package and pinned helper bytes against its compiled authority
before one-shot administrator authorization. The running-code allowlist and
root helper protocol are unchanged. There is no shell tool, executable argument,
credential API, backend override, force unmount, or writer-killing tool.

Open at Login uses `Contents/MacOS/RAMNest --mcp-login-item get|enable|disable`.
The app-owned entry branch executes before SwiftUI/AppModel, and calls
`SMAppService.mainApp` in the RAMNest app executable. It returns actual
`enabled`, `notRegistered`, `requiresApproval`, `notFound` or `unknown` status.
`requiresApproval` requires the user to finish macOS approval. A sealed
`mcp-bridge.json` protocol marker is required before launching either bridge;
an old app cannot accidentally interpret the flag as an ordinary GUI launch.
Automated tests never toggle the user's login item.

Every tool input schema has `additionalProperties: false`, including nested
folder options. Runtime validation rejects unknown keys, nulls, coercions,
noninteger capacities, invalid UUIDs/enums/intervals, relative/unsafe paths and
oversized strings. Capacity is bytes, from 16 MiB through 75% of physical RAM;
periodic intervals are exactly 5, 15, 30, 60, 360, 720 or 1440 minutes. Core
still performs admission, identity, locking, metadata and transaction checks.

Tools return JSON in MCP text content. Operational failures use `isError: true`
with an explicit code/message; unsupported prerequisites never return success.
Read-resource failures are JSON-RPC errors. Cursor pagination is not advertised;
unknown nonempty cursors are rejected.

- `folder_create` registers an **existing** folder. Default `mount=false` avoids
  implicit administrator action; pass `mount=true` for Create and Mount. A failed
  mount reports the created UUID so the retained record can be inspected.
- `folder_delete` keeps originals by default. Destruction requires both
  `destroy=true` and `confirmation="DELETE <canonical-folder-UUID>"`. Checkpoints
  remain until explicit RESET. Confirmation strings must come from a user's
  explicit authorization, not be invented by an agent.
- `settings_reset` requires `confirmation="RESET RAMNEST"`. It uses the app's
  Core RESET contract: save/eject active sync folders, discard temporary RAM
  changes, remove managed records and checkpoints, preserve original folders,
  global preferences and the selected storage location. It does not restart an
  open GUI; restart the GUI manually to discard stale view state.
- `recovery_review` returns reviewed paths/revisions, loss disclosure and a
  random token retained with the actual Core review object in this process.
  This is supported for disk-only legacy journals. Native tmpfs reviewed
  publication recovery is rejected before a token or acceptance write; complete
  that exceptional workflow in the RAMNest app. It needs an app/CLI-owned
  evidence-bound review bridge, not a wider privileged executable allowlist.
  `recovery_confirm` requires that token, `acceptsMissingHistoricRecord=true`,
  and `confirmation="ACCEPT MISSING HISTORIC RECORD"`. The token expires after
  ten minutes and is consumed before confirmation. Core revalidates the full
  evidence under its locks. Cross-session, stale, expired, cancelled and replayed
  reviews fail closed; backups remain. `recovery_cancel` releases a review.
- `storage_move`/`storage_retry` return an accepted **job**, not completed work.
  Poll `storage_status` until `job.running=false`, then inspect `job.error`,
  `pending` and `cleanupPending`. Other store calls return `busy` during work.
  `storage_pause` reaches the actor while copying runs on a separate worker and
  sets Core's cooperative cancellation object. Retry propagates the same
  cancellation API. After commit, cleanup is deliberately not cancellable.
- `settings_update.fileVerification` applies to the next mount. Existing
  sessions/revisions retain their recorded policy. `menuBarMode` is persisted
  and takes effect in an already-open GUI after its next reload. Option updates
  preserve decode-only historic compression data without exposing it as a
  working setting. Periodic saving is effective only with sync enabled.

## Current app control parity

The source inventory covers `ContentView`, `AppSettingsView`, `AppModel`,
`RAMNestCommands`, and `StatusMenuController` in this checkout.

| Human control / display | MCP tool or equivalent | Semantics / prerequisite |
| --- | --- | --- |
| Folder sidebar, refresh, status and attention | `folder_list`, `folder_info` | All configured folders; real Core status |
| Name, path, capacity, kernel usage, snapshot/error details | `folder_info` | Includes folder and journal; no physical-RAM claim |
| New RAM Folder / Choose existing folder | `folder_create.path` | Existing owned directory, Core admission |
| New folder name/capacity/save-on-eject | `folder_create.name/capacityBytes/options.sync` | Remaining defaults or all six options also accepted |
| Create and Mount | `folder_create` with `mount=true` | Valid packaged CLI, interactive admin boundary |
| Mount / menu-bar Mount | `folder_mount` | Packaged CLI |
| Save and Eject / Eject / menu-bar action | `folder_unmount` | Current sync/temporary semantics; no force |
| Busy dialog Ignore / Ignore and Eject | `folder_busy`, `folder_unmount.ignoreBusy` | Mapping gate remains mandatory |
| Reconnect | `folder_reconnect` | Exact surviving native session |
| Save Snapshot | `folder_save` | Close writers/mappings; native safety gate |
| Export Snapshot / destination picker | `folder_export.destination/revision` | New output path; committed disk checkpoint |
| Rescue current RAM by explicit live export | `folder_export.live=true` | Packaged CLI; incompatible with revision selection |
| Recover / menu-bar Recover | `folder_recover` | Explicit recovery; cannot recover destroyed unsaved RAM |
| Review Legacy Recovery | `recovery_review` | Disk-only legacy evidence; native reviewed publication requires the app |
| Accept Missing Record and Complete Recovery | `recovery_confirm` | Disk-only legacy; same-session token and exact explicit acceptance |
| Cancel legacy review | `recovery_cancel` | Token required |
| Edit display name / Apply | `folder_rename` | Does not move original directory |
| Capacity edit / Resize | `folder_resize.capacityBytes` | Idle only; native live resize unsupported |
| Mount at app launch | `folder_options.options.mountAtLaunch` | Persisted for the app; MCP never auto-mounts |
| Hide from Desktop/Finder sidebar | `folder_options.options.nobrowse` | Mount flag on subsequent mount |
| Save changes when ejecting | `folder_options.options.sync` | Current Core behavior |
| Save periodically | `folder_options.options.periodicSave` | Effective with sync and native snapshot capability |
| Save every | `folder_options.options.intervalMinutes` | Exact supported interval enum |
| Snapshot comparison | `folder_options.options.comparison` | `sizeAndModTime` or `checksum` |
| Apply / Discard edits, Normal / Advanced tab | Atomic `folder_options`/`folder_rename`; discard client draft | Presentation/draft controls, no hidden server draft |
| Remove / Keep Folder | `folder_delete` | Default keep; retained checkpoints |
| Delete Folder and second confirmation | `folder_delete.destroy/confirmation` | Exact UUID confirmation |
| Click original path in detail view | `folder_reveal` | macOS Finder request; reports acceptance, not window observation |
| Open in Finder in menu bar | `folder_open` | Desktop required; reports acceptance |
| Snapshot storage path/pending/error/progress | `storage_status` | Includes asynchronous job outcome |
| Choose / Move Snapshot Storage | `storage_move.parent` | Creates private child; all folders must be idle |
| Retry Storage Move / Cleanup | `storage_retry` | Explicit pending work only |
| Pause Before Commit | `storage_pause` | Cooperative worker cancellation, before commit |
| RESET and Restart / Retry RESET | `settings_reset` | Core RESET; GUI restart remains manual |
| File verification for next mount | `settings_get`, `settings_update.fileVerification` | `sha256` default or `sizeAndModTime` |
| Show in menu bar instead of Dock | `settings_update.menuBarMode` | Persisted; running GUI reload needed |
| Open at login | `login_item_get`, `login_item_set.enabled` | App-owned bridge; actual ServiceManagement status |
| Install Command Line Tool / directory picker | `install_cli.directory` | Link to selected signed app CLI; never overwrite |
| Storage engine caption | `capabilities`, `settings_get` | Fixed native tmpfs; no backend choice |
| App compression / FSEvents suppression | `capabilities.unsupported` | Removed/unsupported; no fake option |
| Open RAMNest, Settings window, sheets, selection, Quit app | Client/UI presentation | No app-process lifecycle tool; explicit folder tools cover data work |
| Host memory graph / Help / About | GUI/OS presentation | Not folder settings; no matching MCP telemetry/control |

The server exposes four JSON resources (`ramnest://capabilities`, `folders`,
`settings`, `storage`) and the argument-free `ramnest-safety-review` prompt.
These call the same domain actor and do not bypass its worker exclusion.

## Verification and native handoff

Run the offline domain gate without fetching Swift dependencies:

```sh
bash scripts/mcp-domain-tests.sh "$PWD/artifacts/mcp-domain-verification"
```

It builds real Core and the domain module with generated helper authority, then
uses only owned data folders and stores under `artifacts/`. It covers every
handler's unknown-key/type validation, all options, preference persistence,
create without mount, rename/resize, export/recovery failures, guarded and
explicit owned destructive deletion, RESET, storage selection retention,
worker exclusion/Pause/retry cancellation, and disk-only successful reviewed
legacy recovery with cancellation/cross-session/replay rejection. It does not
claim native mounting from those fixtures.

After dependency access and a successful release build:

```sh
python3 scripts/mcp-protocol-tests.py "$PWD/.build/release/ramnest-mcp"
```

This starts the **actual** SDK server subprocess, exercises strict initialize,
tools/list and calls, all resources, prompt list/get, malformed arguments,
owned store lifecycle, confirmation guards and EOF (also before initialize).
It asserts every stdout line is JSON-RPC. It never mounts or changes app/login
settings. See `MCP_VALIDATION.md` for the current run's observed results.

Native lifecycle requires a successful sealed package and explicit interactive
authorization. It is intentionally not part of ordinary tests. On an available
desktop, with no automated credential entry:

```sh
RAMNEST_MCP_AUTHORIZE_NATIVE_FIXTURE=YES python3 scripts/mcp-native-fixture.py \
  /absolute/RAMNest.app/Contents/Helpers/ramnest-mcp /absolute/RAMNest.app
```

The script creates one owned 32 MiB fixture and isolated bootstrap under
`artifacts/`, then verifies real mount, save, normal unmount and restored bytes.
It cleans only after confirmed success. Failure retains the directory, journals
and all native evidence; it never force-ejects or purges an uncertain mount.
Administrator approval/cancellation, native mapping guard, service EOF/signals,
login-item status/readback and exact-package lifecycle remain separate live
acceptance gates. No real user's fixtures or login preferences are authorized
by running the non-native tests.
