# RepoPrompt CE

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-black)

**The open-source macOS Context IDE for AI coding agents.**

RepoPrompt CE helps you assemble, inspect, and hand off rich codebase context:
pick the right files, summarize project structure and Git history, and package
it all into a dense, reviewable prompt for ChatGPT, Claude, Codex, Cursor, and
other AI coding tools. You can also hand that context straight to agents through
the bundled MCP server and CLI.

## What You Can Do

- Curate focused, reviewable context for an AI model from one or more
  repositories.
- Combine selected files, project-structure maps, function/type CodeMaps, and
  Git diffs in a single prompt.
- Run Context Builder to discover relevant code and produce an optimized prompt.
- Plan, review, and ask follow-up questions in built-in chat, including an
  Oracle flow for second opinions.
- Run longer agent sessions in Agent Mode with supported CLI-backed providers.
- Connect external MCP clients to search, inspect, and select repository context
  from your own tools.

## Project Status

RepoPrompt CE is the open-source community edition of RepoPrompt, originally a
paid macOS app. It removes paid activation flows and license keys while keeping
the core prompt, copy, chat, CodeMap, Agent Mode, and custom-provider features
available without paid license gates. The project is licensed under
[Apache-2.0](LICENSE).

Maintainers track release signing, Sparkle metadata, dependency pins, and
third-party notices in [`docs/open-source-readiness.md`](docs/open-source-readiness.md).

## Requirements

- macOS 14 or later to run the app
- Xcode 26 or matching Command Line Tools with the macOS 26 SDK
- `python3` for the coordinated developer daemon
- Homebrew only when installing SwiftFormat and SwiftLint

RepoPrompt CE does not use an Xcode project. You need Apple's toolchain and SDK,
but you do not need to open Xcode.

## Start Here

From the repository root:

```bash
make doctor    # check toolchain, SDK, signing, SwiftUI symbols, and debug CLI status
make dev-build # build and package .build/debug/RepoPrompt.app
make dev-run   # build, package, stop an existing RepoPrompt process, and launch
```

`make dev-*` commands use the repository's `conductor` daemon. Prefer them for
builds, tests, launches, and style checks so concurrent developers and coding
agents do not run conflicting jobs against the same checkout.

The daemon starts automatically on first use. It serializes jobs that share a
build, package, live-app, release, or style lane and prints a reconnectable
ticket for each job.

## Common Commands

```bash
make dev-status
make dev-build
make dev-swift-build PRODUCT=RepoPrompt
make dev-swift-build PRODUCT=repoprompt-mcp
make dev-test
make dev-test FILTER=WorkspaceFileContextStoreTests
make dev-provider-test
make dev-lint
make guardrails
```

For a user-directed rebuild and relaunch, use:

```bash
./conductor app relaunch
```

This supersedes older queued or active live-app work. `make dev-run` remains
the ordinary FIFO launch path for automation.

Long jobs can run asynchronously:

```bash
./conductor build --async --request-key debug-package
./conductor job wait --request-key debug-package
```

Daemon output is concise by default. It prints progress highlights, a summary,
and the full log path. Add `--full-log` when you need the raw build output:

```bash
./conductor build --full-log
./conductor job wait --request-key debug-package --full-log
```

See [`AGENTS.md`](AGENTS.md) for the complete coordinated validation workflow,
lane behavior, live MCP smoke commands, and source placement rules.

## Direct Fallback

Use direct commands only when `conductor` is unavailable, such as on a machine
without `python3`. They do not coordinate with other developers or agents:

```bash
make build
make run
make test
make lint
```

## Finder Launcher

Open [`Launch RepoPrompt CE.command`](Launch%20RepoPrompt%20CE.command) for an
interactive debug launcher:

- `r` rebuilds and relaunches.
- `s` shows app and daemon-job status.
- `x` stops the app and supersedes older live-app work.
- `q` closes the launcher without stopping the app.

When `python3` is unavailable, the launcher falls back to direct mode.

## Debug Signing

Debug packaging may auto-detect an Apple Development signing identity. To opt
in to persistent debug Keychain storage, pass an explicit identity:

```bash
SIGN_IDENTITY="Apple Development: ..." make dev-build
```

Without a stable identity, explicitly allow an ad-hoc debug build:

```bash
ALLOW_ADHOC_SIGNING=1 make dev-build
```

Ad-hoc debug builds use in-memory secure storage, so API keys and secure
permission changes do not persist across launches. Release packaging requires
`SIGN_IDENTITY`.

## Debug CLI

Use the CE-specific debug CLI for live app and MCP checks. Production
`rp-cli` / `rp-cli-debug` commands may connect to the non-CE app.

```bash
make install-debug-cli
make debug-cli-status
make dev-smoke        # requires an already-running debug app
make dev-smoke-launch # builds, launches, and runs the smoke flow
```

## Contributing

New issues and pull requests from accounts outside the maintainer-managed
contributor gate are closed automatically. The private allowlist does not grant
repository access or organization membership. See [`CONTRIBUTING.md`](CONTRIBUTING.md)
for the full contribution policy.

Before opening a pull request, run:

```bash
make guardrails
make dev-lint
```

Add the smallest relevant `make dev-test FILTER=<SuiteName>` coverage for
behavior changes.

## Source Layout

Product flows live under `Sources/RepoPrompt/Features`, app composition under
`Sources/RepoPrompt/App`, shared infrastructure under
`Sources/RepoPrompt/Infrastructure`, shared MCP protocol code under
`Sources/RepoPromptShared/MCP`, and tests under `Tests/RepoPromptTests`.

See [`docs/architecture/source-layout.md`](docs/architecture/source-layout.md)
for the ownership map and documented exceptions.

## Release Packaging

Contributors can exercise release packaging without credentials:

```bash
make dev-release-preflight
make dev-release-artifact
```

The generated archive is ad-hoc signed and is not distributable. Maintainers
publish Developer ID signed, notarized GitHub Releases through the protected
workflow documented in [`docs/releasing.md`](docs/releasing.md). See
[`docs/open-source-readiness.md`](docs/open-source-readiness.md) for the
remaining public-readiness inventory.
