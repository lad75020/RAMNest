# MCP validation record — 2026-11-09

The release server and sealed app package have been built successfully. Actual
stdio protocol and isolated domain tests pass. Native administrator-authorized
lifecycle and login-item behavior remain **unverified**; this is not full native
acceptance. No user store, active mount, installed app, login preference or global
setting was changed. Existing metadata/recovery work was preserved; the only
addition to a previously dirty tracked file is the storage-retry cancellation API
in `Store.swift`. No commit, push, reset, stash or checkout was performed.

## Parent-observed passing checks

| Scope | Result | Evidence |
| --- | --- | --- |
| Release official-SDK executable | Exit 0 | `artifacts/mcp-parent-release-build.log` |
| `swift test --filter ActivitiesTests` | Exit 0; one comprehensive scenario test passed | `artifacts/mcp-parent-swift-tests.log` |
| Offline owned domain executable | Exit 0; `PASS owned MCP schema/handler/store scenarios` | `artifacts/mcp-parent-domain-tests.log` |
| Actual release stdio JSON-RPC suite | Exit 0; 30 tools, 4 resources, 1 prompt, owned lifecycle, strict arguments, EOF | `artifacts/mcp-parent-protocol.log` |
| Complete release app/ZIP/source package | Exit 0, including asset compilation | `artifacts/mcp-parent-package.log` and `artifacts/mcp-parent-package/artifacts/logs/` |
| Exact packaged server stdio suite | Exit 0 | `artifacts/mcp-parent-packaged-protocol.log` |
| `codesign --verify --deep --strict` on produced app | Exit 0 | Parent tool execution |
| ZIP/source `shasum -a 256 -c` | Both OK | `artifacts/mcp-parent-package/artifacts/SHA256SUMS` |
| Produced server `otool -L` | System frameworks/runtime only; no external Core dylib or FUSE | Parent tool execution |
| `git diff --check` | Exit 0 | Parent tool execution |

Parent release build command:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/mcp-parent-cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/mcp-parent-cache/clang" \
swift build --disable-sandbox --cache-path .build/mcp-parent-cache \
  --scratch-path .build/mcp-parent-release -c release --product ramnest-mcp
```

The same cache/scratch arguments were used with `swift test --filter ActivitiesTests`.
The package command was `bash scripts/package.sh --output "$PWD/artifacts/mcp-parent-package"`.
The protocol command was `python3 scripts/mcp-protocol-tests.py EXECUTABLE`, run
against both `.build/mcp-parent-release/release/ramnest-mcp` and the packaged
`Contents/Helpers/ramnest-mcp`.

## Artifacts

- `artifacts/mcp-parent-package/artifacts/RAMNest.app/Contents/Helpers/ramnest-mcp`
- `artifacts/mcp-parent-package/artifacts/RAMNest-1.0.0-macos27-arm64.zip`
- `artifacts/mcp-parent-package/artifacts/RAMNest-1.0.0-source.tar.gz`
- `artifacts/mcp-parent-package/artifacts/SHA256SUMS`

The package is development/ad-hoc signed, not notarized. It has not replaced the
installed RAMNest application and is not registered in an MCP client.

## Test coverage and boundaries

The domain scenarios exercise all tools' unknown-key/null validation, all six
folder options, global preferences, no-mount create, rename/resize, verified disk
checkpoint export and errors, idle recovery errors, keep-original and explicitly
confirmed disposable delete, RESET and selected-storage retention. They also
exercise storage moves, active-worker exclusion, Pause/retry cancellation and
successful disk-only reviewed recovery with cancellation, cross-session and
replay rejection. These tests do not prove native mounts.

The real SDK subprocess suite exercises initialization, pre-initialize ping,
tools/list/call, all resources, prompt list/get, invalid arguments and confirmation
guards, isolated store lifecycle, clean EOF before/after initialization and SIGTERM.
Every stdout line must parse as JSON-RPC. SDK 0.12.1 drops non-ping pre-initialize
requests without returning a wire error, so the suite does not assert otherwise.

The delegated build was initially blocked by sandbox DNS and asset-writing
failures. Parent host execution fetched the genuine pinned dependencies and
compiled the assets successfully. A separate actual SwiftPM plugin toolchain
failure (CMake could not discover make/compiler) was fixed by setting a bounded
command-local PATH in `swiftpm-native-authority.sh`; no global toolchain or
security settings were changed. No stub SDK, default authority hash or native
runtime bypass was used.

## Remaining live acceptance

- Native mount/save/unmount and restored-content verification, one-shot
  administrator approval/cancellation and live mapping/reference guard.
- App-scoped Open at Login status/update/readback and macOS user approval.
- Finder request/window observation, running-GUI preference application.
- Exceptional native reviewed-publication recovery remains unsupported through
  MCP; use the RAMNest app. Ordinary native recovery still uses its packaged CLI.

## Focused review remediation

Independent review found that native reviewed-publication confirmation would
persist acceptance before failing Core's privileged caller allowlist. MCP now
rejects native reviewed recovery before issuing a review token, and rechecks
before confirmation. Native backend and native-record admission regressions were
added; disk-only legacy review remains supported. No helper allowlist was widened.

The owned native fixture is provided in `scripts/mcp-native-fixture.py`. It requires
explicit interactive authorization as documented in `MCP.md`, uses a new 32 MiB
fixture/isolated bootstrap, and retains evidence on failure rather than forcing an
unmount or purging uncertain data. Do not run acceptance against real user data.

Current presentation limitations are documented in the parity matrix in `MCP.md`:
running-GUI menu-mode refresh and GUI restart remain manual; UI windows, Help,
About, Quit and the host memory graph are not MCP app-process controls.
