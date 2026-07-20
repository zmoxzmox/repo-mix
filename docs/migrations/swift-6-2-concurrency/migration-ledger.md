# Swift 6.2 Concurrency Migration Ledger

Updated: 2026-07-20

## Toolchain and policy

- Active compiler: Apple Swift 6.2.4 (`swift-driver` 1.127.15), arm64-apple-macosx26.0.
- Root package tools version: 6.2; package default and all non-Item-6 targets remain in Swift 5 language mode.
- Migration policy: target-scoped complete strict-concurrency checking first, followed by independently evidenced target-local `.swiftLanguageMode(.v6)`. No default MainActor or Swift 6.2 execution/isolation feature is adopted by this tranche.

## Completed boundaries

| Boundary | Commit / state | Language/checking | Evidence |
| --- | --- | --- | --- |
| Dependency/grammar upgrade and broad parser-lock removal | `3b330db9fdfad6c23e715c84d47877995214f1c7` | Swift 5 | Exact SwiftTreeSitter 0.10/runtime 0.25.10 and grammar revisions; scanner shim retained after clean-link proof. |
| `RepoPromptRegexCore` | extraction `6feead2fcfbbd53bc9d4b9d0255401ec51bfd374`; Item 6 this change | Swift 6 | Production and owner-test targets compile with `-swift-version 6`; eight owner tests and Swift 5 app-consumer linkage pass. |
| `RepoPromptCodeMapCore` / owner tests | extraction `22bfff1c5904d5f02c0a881055142c94f4783a84`; Item 6 this change | Swift 6 | Production and owner-test targets compile with `-swift-version 6`; 16 owner tests, mixed-mode app tests, and both Swift 5 product builds pass. |

## Item 3 ownership record

Moved to `RepoPromptCodeMapCore`:

- provenance-free decoder policy/raw digest/decoded result vocabulary with pipeline and artifact-key canonical encoding;
- immutable grammar/pipeline descriptors, exact CodeMap-only query bytes, extension registry, parse limits, and synchronous Tree-sitter execution;
- syntax artifact outcomes/builder, capture indexing, extraction memoization, signature/type helpers, language strategies, generator, and path-free canonical artifact rendering;
- invocation-local parser, query cursor, extraction memo, and performance collector state.

Split or retained in `RepoPromptApp`:

- decoder and SHA construction authority, exact raw bytes, validation tokens, Git/worktree provenance, and workspace decoder;
- direct SwiftTreeSitter highlighting linkage and mutable highlight/language caches;
- build permits, priority, pre/post parse cancellation, coordinator flights/fairness, environment flags, and performance aggregation;
- CAS/container/catalog/locator/manifest persistence, workspace/Git authority, token and path/import presentation, selection-graph policy, UI, and MCP.

Test ownership:

- `RepoPromptCodeMapCoreTests` is the sole owner of pure CodeMap parsing fixtures, goldens, canonical byte tests, deterministic negative outcomes, registry/query bytes, and concurrent all-language initialization/build checks.
- `RepoPromptTests` retains adapter, coordinator/cancellation, persistence/CAS, workspace, presentation, highlighting, UI, and MCP integration tests.

## Strict-concurrency diagnostics and escape-hatch inventory

- `RepoPromptRegexCore`, `RepoPromptCodeMapCore`, `RepoPromptRegexCoreTests`, and `RepoPromptCodeMapCoreTests` now use target-local Swift 6 language mode. Verbose SwiftPM compiler invocations contain `-swift-version 6` for exactly those four modules; `RepoPromptApp`, `RepoPromptTests`, and `RepoPromptMCP` remain `-swift-version 5` consumers. No invocation adds default MainActor, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, or another execution/isolation feature.
- Parser and cursor objects remain invocation-local and never cross a Sendable boundary. Public cross-target graphs remain package-visible immutable Sendable values.

| Escape hatch | Scope | Preserved invariant | Audit / removal condition |
| --- | --- | --- | --- |
| `nonisolated(unsafe)` on standard-library `Regex` constants | 25 existing annotations in `LanguageTypeExtractor` | Every value is immutable and initialized once; matching is nonmutating; no mutable shared cache or escaping match state is hidden by the annotation. The annotation exists because the standard-library `Regex` output metadata used here does not expose Sendable conformance. | Re-audit when the deployed Swift standard library makes these concrete/type-erased `Regex` values Sendable; remove only when the active minimum toolchain compiles the declarations without the escape hatch. |
| `PCRE2Regex: @unchecked Sendable` | One existing class in `RepoPromptRegexCore` | Compilation, including JIT, completes before publication and the compiled `pcre2_code` is immutable afterward. Ordinary matches allocate independent match data/context; `MatchSession` owns mutable state, is deliberately non-Sendable, and is confined to one sequential consumer. A live call retains the regex, preventing deinitialization from racing the call. The current implementation therefore needs no lock around immutable compiled code. | Re-audit on a PCRE2 upgrade or any change that shares mutable match/session state, mutates compiled code after publication, or changes lifetime ownership. |

No new escape hatch or source annotation was added for Item 6. The four target logs and raw verbose invocation evidence contain zero diagnostics attributed to their source or owner-test paths.

## Item 3 evidence

- Baseline golden: conductor ticket `880de0e6…` — 14 language fixture/golden comparisons passed before extraction.
- Baseline syntax artifact: ticket `b10a0628…` — six deterministic artifact/outcome tests passed before extraction.
- Baseline authoritative test list: ticket `fdb54f9e…`.
- Extracted canonical key/registry/concurrency suite: ticket `d690b814…` — passed under the owner target.
- Complete owner target: ticket `5928f578…` — 16 tests passed (9 canonical key/registry/concurrency, 1 golden corpus test covering 14 files, and 6 artifact/outcome tests); log grep found zero warnings or errors attributed to `Sources/RepoPromptCodeMapCore` or `Tests/RepoPromptCodeMapCoreTests`.
- Focused app integration: ticket `e5eacaf7…` — 95 adapter, app golden/presentation, coordinator, container, store, and workspace-binding tests passed, including 35 coordinator retry/cancellation/CAS tests.
- Byte-identity audit: all 27 moved fixture/golden resources and all 13 CodeMap query literal bodies exactly match `HEAD` before extraction; `Package.resolved` is unchanged.
- Authoritative root test list: ticket `c590972a…`; exact ledger verification passed at 3,451 IDs with final root ticket `3f92a87b…` and provider ticket `4257122f…`.
- SwiftFormat mutation: ticket `e673cfbe…`; strict formatter/lint: final ticket `e7c517b7…`; source/license guardrails passed.
- Coordinated ad-hoc debug package and authorized relaunch: ticket `25a7eb0b…`; package/build/signature/launch completed. The debug app uses documented ephemeral secure storage; no live MCP behavior test was required for the synchronous internal seam.

## Item 6 Swift 6 language-mode evidence

- Swift 5 staged baseline: Regex owner tests ticket `7dfd535b…`; CodeMap owner tests ticket `2016de2d…`; both passed before the manifest change.
- Swift 6 owner tests: Regex ticket `7730d2a9…` (8 tests); CodeMap ticket `f97a9002…` (16 tests); zero failures and zero in-scope compiler diagnostics.
- Verbose compiler invocations under Apple Swift 6.2.4: `RepoPromptRegexCore`, `RepoPromptCodeMapCore`, `RepoPromptRegexCoreTests`, and `RepoPromptCodeMapCoreTests` each received `-swift-version 6`. Both CodeMap targets retained their conditional manifest `DEBUG` definition. `RepoPromptApp` and `RepoPromptTests` received `-swift-version 5`; the coordinated MCP build description also recorded `RepoPromptMCP` at `-swift-version 5`.
- Mixed-mode app tests: coordinator ticket `c21ae5d2…` (37 tests), source-snapshot adapter ticket `16782ea7…` (1 test), and app CodeMap golden/presentation ticket `499e8a76…` (4 tests); zero failures.
- Swift 5 consumer products: RepoPrompt ticket `6c091ce4…`; repoprompt-mcp ticket `afed7b28…`; both built successfully.
- Phase boundary: full root ticket `a5f3c831…` passed in 9m28s; full provider ticket `11ad3aad…` passed; lint ticket `ce6cd2f4…`, 23 generator contract tests, and source/license guardrails passed.
- Package default remains `swiftLanguageModes: [.v5]`; `Package.resolved` and all source files are unchanged.

## Generated-Xcode status

`make xcode-generator-test` passes all 23 generator contracts. A fresh `make xcode-validate` still stops at `xcodebuild -list` with error 74, `Couldn’t update repository submodules`. This remains the separately documented upstream SwiftTreeSitter/Neon `tree-sitter-swift` gitlink/custom-path generated-workspace blocker. It does not invalidate the clean SwiftPM target-local Swift 6 compiler evidence, and Item 6 does not create forks, rewrite dependency URLs, or apply an unsafe package workaround.
