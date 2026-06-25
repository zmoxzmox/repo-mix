# Testing RepoPrompt CE

Use this guide for contributor-facing XCTest changes. Follow `AGENTS.md` for coordinated daemon use, style checks, and lifecycle approvals. Use `$rpce-test-quality` when deciding whether coverage is worth adding, retaining, consolidating, or removing.

## Quality gate before adding a test

Add a test only when all four answers are concrete:

1. **Contract:** What current behavior must remain true?
2. **Plausible defect:** What realistic regression would violate it, and what is the impact?
3. **Lowest faithful layer:** Can deterministic core or provider-package coverage reproduce the risk, or is root SwiftPM integration actually required?
4. **Observable oracle:** What exact output, state, error, side effect, cleanup, wire format, or bounded performance result distinguishes broken from correct behavior?

Search existing direct and outcome-level coverage first. Prefer a test that fails against known-bad behavior. Do not add invocation-only, no-crash, non-nil-only, source-shape, symbol-presence, constant-restatement, arbitrary-sleep, or coverage-driven tests unless that fact is itself the contract and no stronger oracle exists.

## Add a root or provider XCTest

- **Root target:** place app-integrated and root-package tests under `Tests/RepoPromptTests` and validate with `make dev-test`.
- **Provider target:** place provider protocol, codec, translation, launch-argument, or model-mapping tests under `Packages/RepoPromptAgentProviders/Tests/RepoPromptClaudeCompatibleProviderTests` and validate with `make dev-provider-test`.
- Keep one coherent contract per method. Labeled tables are appropriate when cases differ only by input, boundary, or expected outcome.
- Control time, randomness, environment, resources, ordering, and concurrency. Prefer gates, clocks, or continuations over sleeps, and verify meaningful cleanup or ownership.

Focused daemon-coordinated examples:

```bash
make dev-test FILTER=RepoPromptTests.ExampleTests
make dev-test FILTER=RepoPromptTests.ExampleTests/testBehavior
make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.ExampleTests
make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.ExampleTests/testBehavior
```

Use the narrowest relevant filter, then broaden only for the affected boundary.

## Authoritative executable IDs

Never derive the executable census from source text or a stale build. Use:

```bash
make dev-test-list
make dev-provider-test-list
```

Listed XCTest IDs have these shapes:

```text
RepoPromptTests.<Suite>/testMethod
RepoPromptClaudeCompatibleProviderTests.<Suite>/testMethod
```

The curated ledger prefixes the target:

```text
root/RepoPromptTests.<Suite>/testMethod
provider/RepoPromptClaudeCompatibleProviderTests.<Suite>/testMethod
```

Treat these strings as exact, case-sensitive identifiers.

## Maintain the contract ledger surgically

Every executable add, rename, consolidation, or removal requires an atomic, surgical update to `Scripts/Fixtures/test-suite-contract-ledger.tsv`. Never regenerate or overwrite the curated ledger. In particular, do not point `inventory --force` at it.

The TSV header order is fixed. Every live row carries identity/location fields (`method_id`, `target`, `file`, `suite`, `method`, `domain`, `layer`), contract fields (`primary_contract_id`, `secondary_contract_tags`, `validation_class`, `scenario_count`, `fixture_ids`, `observable_oracle`, `failure_risk`), cost/ownership fields (`runtime_seconds`, `resource_cost_tags`, `shared_state_tags`, `lifecycle_owner`), and disposition fields (`current_disposition`, `replacement_method_id`, `preserved_scenario_delta`, `notes`).

For every new or touched row:

- use reviewed, specific contract, oracle, risk, validation-class, and lifecycle values rather than `unreviewed`;
- set optional fixture/resource/shared-state tags when applicable and leave them blank only when none apply;
- use `current_disposition=retain` for a new independent test or a reviewed retained test;
- use `current_disposition=consolidated_replacement` for a live method replacing multiple old methods;
- do not introduce `retain_pending_review`; it is initial-scaffold debt;
- keep `replacement_method_id` blank on live rows because stale removed rows cannot remain in an exact-ID ledger;
- use `preserved_scenario_delta=0` when scenarios are preserved, including table consolidation; justify any nonzero delta in `notes` and the handoff.

### Scenario count

`scenario_count` is the number of distinct input, boundary, outcome, fixture, or lifecycle scenarios protected by the method. It is **not** the assertion count. Consolidating methods into a table lowers executable method count without lowering scenario count unless coverage is deliberately removed.

### Atomic rename, consolidation, and removal workflow

1. Before editing, capture the authoritative target list, the exact old IDs, and scenario totals.
2. Change the XCTest declarations and ledger rows in the same patch.
3. **Rename:** replace the old live row with the new exact ID and record `old ID -> new ID` in `notes` and the handoff.
4. **Consolidate:** delete every obsolete row, add the live replacement row(s), set each replacement's `scenario_count` to the preserved scenario total, and enumerate every exact old ID in `notes`. Record the complete `old IDs -> new ID` mapping in the handoff.
5. **Remove without replacement:** delete the stale row and record `old ID -> removed` plus the duplicate, obsolete/non-contractual, or intentionally-unprotected rationale in the handoff. Campaign removals also go in the append-only scoreboard.
6. Re-list, recount, and verify. No obsolete ID may remain, and no new ID may be absent.

## Verify exact-ID reconciliation

Run:

```bash
python3 Scripts/test_suite_optimizer.py verify-ledger \
  --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv
```

This command validates the exact header schema, duplicate ledger IDs, and equality between live root/provider executable IDs and ledger IDs. It **does not** validate scenario totals, contract metadata completeness, disposition correctness, replacement mappings, or the truth of any descriptive field. Review those manually.

## Summarize scenario totals

Run this before and after a consolidation. Set `SUITES` to a comma-separated list of affected fully qualified suites. Save both outputs and report affected-suite and repository target totals.

```bash
SUITES='RepoPromptTests.ExampleTests' python3 - <<'PY'
import csv, os
from collections import Counter

path = "Scripts/Fixtures/test-suite-contract-ledger.tsv"
wanted = {s for s in os.environ.get("SUITES", "").split(",") if s}
by_target, by_suite = Counter(), Counter()
with open(path, encoding="utf-8", newline="") as handle:
    for row in csv.DictReader(handle, delimiter="\t"):
        count = int(row["scenario_count"])
        by_target[row["target"]] += count
        by_suite[(row["target"], row["suite"])] += count
for target in sorted(by_target):
    print(f"target\t{target}\t{by_target[target]}")
print(f"repository\ttotal\t{sum(by_target.values())}")
for (target, suite), count in sorted(by_suite.items()):
    if not wanted or suite in wanted:
        print(f"suite\t{target}\t{suite}\t{count}")
PY
```

For consolidations, a zero repository and affected-suite scenario delta is the default acceptance criterion. Any intentional delta requires explicit contract-level justification.

## Evidence tiers

### Ordinary test changes

At minimum, provide:

1. the focused root or provider test command and result;
2. the affected target's authoritative list command and result;
3. the `verify-ledger` command and result;
4. required style/guardrail validation from `AGENTS.md` when applicable.

Ordinary additions, fixes, renames, and removals do not need timing artifacts merely because the harness exists.

### Optimization or performance campaigns

In addition to ordinary evidence, create new append-only inventory, baseline, focused, and full-root artifacts and append the result to `prompt-exports/optimize-test-suite-runs.md`. Never rewrite earlier artifacts or scoreboard history.

Collect 3–5 comparable normal timing samples per measured series. Root and provider timings remain separate. Use a fresh temporary generated ledger path when creating the append-only inventory artifact; never use the curated ledger as inventory output:

```bash
label=example-campaign
inventory="prompt-exports/test-suite-inventory-${label}.json"
baseline="prompt-exports/test-suite-baseline-root-${label}.json"
tmpdir="$(mktemp -d)"
python3 Scripts/test_suite_optimizer.py inventory \
  --ledger "$tmpdir/generated-ledger.tsv" \
  --output "$inventory"
rm -rf "$tmpdir"

python3 Scripts/test_suite_optimizer.py baseline \
  --target root \
  --samples 5 \
  --label "$label" \
  --inventory "$inventory" \
  --scoreboard prompt-exports/optimize-test-suite-runs.md \
  --output "$baseline"
```

Normal timing samples must not enable XCTest stall diagnostics or wake probes. Diagnostic/wake-probe runs are invalid timing samples and may be retained only as separate lifecycle evidence. The scoreboard must report method, contract, and scenario deltas; exact replacement/removal mappings; comparable sample counts; focused/full-root outcomes; and artifact paths.

## Live Agent Mode file-tool performance diagnostic

`Scripts/benchmark_agent_mode_file_tools.py` measures paired `file_search` and `read_file` calls from exactly two concurrent Explore sessions: the normal workspace root and a linked worktree. It requires an already-running RepoPrompt CE DEBUG app and never launches, stops, or relaunches the app.

```bash
python3 Scripts/benchmark_agent_mode_file_tools.py \
  --window-id 1 \
  --marker debugDiagnosticsToolName \
  --path Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift
```

By default the driver creates a detached temporary worktree and removes it only when it remains clean and both sessions are terminal; pass `--worktree /absolute/path` to use and preserve an existing linked worktree from the same Git common directory. The manifest records the benchmark worktree's SHA and dirty state. Each run writes a private (`0700`), non-overwriting directory under `/tmp/rpce-agent-file-tools/v1/`; use `--output-root` to override it. Artifacts include provenance, raw CLI calls and agent logs, capture/runtime snapshots, `samples.ndjson`, and `summary.json`, and may contain sensitive workspace snippets, so review them before sharing. Samples and exact workload counts/order come from DEBUG capture timelines (`Received` through the `event_completion` `MainActorExited`); start/wait binding metadata independently proves local-versus-worktree route provenance, while compacted agent logs validate only surfaced call arguments and the final response. Latency is report-only and has no arbitrary failure threshold. Harness, tool-count, nonempty-marker, read-success, and cleanup invariants are enforced.

Offline replay performs no CLI, model, or app calls and accepts either a checked-in fixture or a prior artifact directory:

```bash
python3 Scripts/benchmark_agent_mode_file_tools.py \
  --replay Scripts/Fixtures/agent-mode-file-tools/v1/paired-success
```

The checked-in success and negative fixtures are privacy-scrubbed subsets derived from real paired captures. They retain relevant event/stage timing shapes but contain no raw agent prose, user paths, UUIDs, or raw logs.

Pure harness validation:

```bash
python3 -m py_compile Scripts/benchmark_agent_mode_file_tools.py Scripts/test_agent_mode_file_tools_benchmark.py
python3 Scripts/test_agent_mode_file_tools_benchmark.py
```

## Live large-workspace worktree-startup diagnostic

`Scripts/worktree_startup_live_benchmark.py` is the reusable validation lane for
large-root and linked-worktree startup. It drives `rpce-cli-debug` and the
DEBUG-only `worktree_startup_benchmark` diagnostics. It never builds, installs,
launches, stops, or relaunches RepoPrompt. A fresh-process (cold) run therefore
requires a separately approved relaunch before invoking the script; label a run
`cold` only when that boundary is true. An aged run requires the configured
minimum existing Agent Mode session count and keeps aged and warm samples in
separate distributions.

This is a runtime diagnostic, not XCTest coverage. It does not add executable
test IDs and must not change the curated test ledger.

### Dedicated workspace and plan

Use a disposable workspace whose name starts with `RPCE 8E Bench `. Never use
the active development checkout: the driver rejects its own repository root.
Create/open a separate disposable root with `rpce-cli-debug`, bind the benchmark
tab, and record its exact window, workspace, context, and root IDs. A name or
current selection is not proof of isolation. Create an exclusive root marker
with a new owner UUID after those stable IDs exist:

```bash
OWNER_TOKEN="$(uuidgen)"
python3 Scripts/worktree_startup_live_benchmark.py create-marker \
  --root-path /absolute/path/to/disposable/large/repository \
  --workspace-id '<workspace-uuid>' \
  --root-id '<root-uuid>' \
  --owner-token "$OWNER_TOKEN" \
  --confirm-disposable-root
```

The marker binds its canonical root, workspace UUID, root UUID, owner token,
disposable purpose, and SHA-256 digest. Preflight/run/smoke/cleanup also resolve
the workspace by UUID through `manage_workspaces`, require the exact name and
root membership, and require the planned root to be the sole root before and
after the campaign. A missing, changed, renamed, system/current-only, or
operator-named substitute is rejected. Workspace creation, root
addition/removal, and visible window changes can request app approval; prepare
the workspace before the campaign.

Write an immutable plan without contacting the app:

```bash
python3 Scripts/worktree_startup_live_benchmark.py plan \
  --workspace-name "RPCE 8E Bench 20260625T120000Z" \
  --window-id 3 \
  --workspace-id '<workspace-uuid>' \
  --context-id '<context-uuid>' \
  --root-id '<root-uuid>' \
  --root-path /absolute/path/to/large/repository \
  --owner-token "$OWNER_TOKEN" \
  --dataset-label rpce-large \
  --asserted-file-count 100000 \
  --base-ref HEAD \
  --search-marker WorkspaceRootSeedPlanner \
  --read-path Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceRootSeedPlanner.swift \
  --read-marker WorkspaceRootSeedPlanner \
  --invocations-per-series 3 \
  --output /tmp/rpce-worktree-startup-plan.json
```

`asserted_file_count` is operator-supplied provenance, not an app measurement.
The plan freezes the ownership-marker digest; do not recreate or edit the marker
between cohorts.
The plan records the complete required matrix: baseline, forced-full, and
projected routes; cold, warm, and aged processes; main checkout and linked
worktree; widths 1/2/4/8; nested inherited-worktree Agent Mode; selection and
`get_code_structure`; exact-root/cross-root negatives; non-Git behavior;
watcher create/edit/rename/delete; and ordinary/worktree root churn while
agents remain active and while file/search/selection/codemap calls are in
flight.

Run schema discovery and exact-scope verification before mutation:

Explicitly enable the DEBUG-only gate for the campaign; the harness verifies it
but never changes this global setting on the operator's behalf:

```bash
rpce-cli-debug -w 3 -c app_settings -j \
  '{"op":"set","key":"agent_mode.worktree_startup_benchmark_diagnostics_enabled","value":true}'
```

```bash
python3 Scripts/worktree_startup_live_benchmark.py preflight \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --confirm-live-debug-app
```

Preflight freezes SHA-256 hashes for the relevant CLI schemas and requires the
DEBUG benchmark token plus `manage_workspaces.remove_folder`. A schema or scope
change invalidates the campaign; do not silently substitute IDs.
Restore the gate to its prior value after all run/smoke cleanup completes.

### Route and concurrency cohorts

Run one route/process/checkout/width series at a time. Every retained series
uses one excluded warmup and 3–5 normal samples; five is the release-gate
default. The plan defaults to exactly three invocation artifacts per matrix
cell. Valid slow samples remain included. A rerun gets a new invocation ID and
never replaces the old artifact; an unplanned extra invocation makes the
campaign incomplete rather than supplying replacement samples.

```bash
python3 Scripts/worktree_startup_live_benchmark.py run \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --route forced-full \
  --process-state warm \
  --checkout-kind linked-worktree \
  --width 4 \
  --invocation 1 \
  --warmups 1 \
  --samples 5 \
  --confirm-live-debug-app \
  --confirm-process-state
```

Repeat for `baseline`, `forced-full`, and `projected`; process states `cold`,
`warm`, and `aged`; and widths 1/2/4/8. Automated route samples are always
app-created `linked-worktree` starts. `baseline` is the ordinary automatic
full-crawl control.
`forced-full` forces that safe route. `projected` is valid only when the export
contains exactly one `diffSeedServing` publication, no `fullCrawl`, and no
fallback. Observation/full-crawl data is work-attribution evidence, not a
projected-serving latency sample.

Actual-route accounting is exact: baseline and forced-full each require exactly
`{"fullCrawl":1}`, projected requires exactly `{"diffSeedServing":1}`, and
every cohort requires an empty fallback map. Configured route names alone never
satisfy the gate.

The current DEBUG token does not measure initial main-workspace opening. Capture
main-checkout cold/warm root-ready/search/read separately from the existing
restore/readiness diagnostics and retain it beside the campaign; the driver
does not offer a label-only `main` route that could be mistaken for a real
measurement. If that evidence is absent, the final decision is `incomplete`,
never a pass.
Record reviewed external evidence in the same plan namespace rather than
putting an unstructured claim in the scoreboard:

```bash
python3 Scripts/worktree_startup_live_benchmark.py record-evidence \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --scenario cold-main-workspace-open-root-ready \
  --status pass \
  --details /tmp/cold-main-sanitized-details.json \
  --output /tmp/cold-main-evidence.json
```

Also record `main-checkout-cold-warm-root-search-read`. The other required
records are `fresh-process-provenance`,
`aged-process-session-and-thread-inventory`, and
`host-sleep-and-thermal-validity`. `aggregate --evidence <file>` accepts each
reviewed record; missing or plan-mismatched evidence keeps the gate incomplete.

Each sample records correlation-scoped:

- p50/p95 materialize-to-root-ready, first-search completion, and first-read
  completion;
- first search/read tool duration;
- configured and actual route plus every fallback reason;
- Git command count, family, priority, duration, and queue wait;
- filesystem operation/item/duration counts and codemap attribution;
- process CPU, average/peak core utilization, peak and retained resident memory,
  and peak and retained physical footprint;
- content oracles, receipt ambiguity/eviction, and cleanup state.

Every sample record, diagnostic export, and ordinal has a one-to-one mapping
to a unique correlation UUID and unique Agent Mode session UUID. Aggregation
rejects reuse, disagreement between record/export IDs, duplicate ordinals,
mixed artifact/cohort identities, and extra or missing invocation/sample
counts. Any attempted sample—including an excluded warmup—with route,
attribution, or correctness failure invalidates the cohort and campaign; valid
extras cannot mask it.

### Correctness, watchers, and root churn

Run the smoke lane after route sampling:

```bash
python3 Scripts/worktree_startup_live_benchmark.py smoke \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --confirm-live-debug-app \
  --confirm-dedicated-workspace
```

The smoke lane uses a script-owned app worktree and temporary roots. It checks:

- a nested child started from the parent context has the exact parent session
  and inherited worktree, reaches terminal `completed`, returns the expected
  marker, and has one ordered inherited-root `file_search` plus `read_file`
  tool-call/result pair in its structured transcript. Prompt/request text,
  assistant prose, missing result payloads, or non-success tool status cannot
  satisfy this check;
- selection and explicit/selected `get_code_structure` return the exact planned
  canonical root UUID/path/type and exact file path/type/content in structured
  MCP JSON, and exclude cross-root/non-Git records;
- main/worktree/non-Git marker searches do not leak across explicit root filters;
- non-Git search/read work and codemap returns an explicit typed unavailable
  status and issue code rather than a
  graph from another root, with exactly one attributed `get_code_structure`
  work record and zero Git commands;
- watcher create, edit, rename, and delete converge via bounded polling of
  structured exact-root success/empty records;
- before, during, and after every ordinary/linked-worktree add/remove, the
  parent remains `running` on the identical context and the during-poll overlaps
  the mutation interval;
- added roots appear in the exact workspace inventory and pass search/read,
  selection, and codemap checks; removed roots disappear from inventory and
  revoke search/read/selection/codemap state;
- add/remove overlaps at least one in-flight `file_search`, `read_file`,
  selection, or `get_code_structure` subprocess call, rather than claiming a
  race from calls that already completed;
- removed-root search/read/codemap calls retain successful CLI/tool transport
  and return an explicit `not_found`, `unavailable`, or `removed` status plus a
  recognized typed issue code for the exact former root UUID/path. Generic CLI,
  transport, or tool failure is a test failure; surviving roots must still be
  usable through exact-root structured records.

The harness records and checks parent and child terminal status, removes only
roots it added, cancels/waits only sessions it started, and removes registered,
clean, script-owned worktrees only after every relevant agent is terminal or
cancelled. Cleanup evidence must include terminal agents, removed secondary
roots/worktrees, restored route control, unchanged benchmark setting, successful
diagnostic reset, stopped resource sampling, and restoration to the sole planned
root. Dirty, nonterminal, missing-identity, or otherwise ambiguous resources are
preserved for manual cleanup. Resume interrupted cleanup with:

```bash
python3 Scripts/worktree_startup_live_benchmark.py cleanup \
  --artifact /tmp/rpce-worktree-startup/v1/<run> \
  --confirm-live-debug-app \
  --confirm-owned-resources
```

Resumed cleanup always sends a memory-sampler stop request and follows it with
an explicit current-state query. Both calls must succeed and report
`running:false`; a stale state-file flag is not accepted. Worktree removal still
occurs only after all recorded agents are terminal/cancelled.

Raw CLI responses may contain paths or source snippets. Run directories are
created non-overwriting with mode `0700`; files use `0600`. Review before
sharing. Summary/scoreboard output must not be treated as privacy-scrubbed raw
evidence.

### Aggregation, thresholds, and append-only scoreboard

Aggregate offline after collecting every matrix cell and correctness smoke:

```bash
python3 Scripts/worktree_startup_live_benchmark.py aggregate \
  --plan /tmp/rpce-worktree-startup-plan.json \
  --artifact /tmp/rpce-worktree-startup/v1/<run-1> \
  --artifact /tmp/rpce-worktree-startup/v1/<run-2> \
  --evidence /tmp/cold-main-evidence.json \
  --output /tmp/rpce-worktree-startup-aggregate
```

The aggregate emits `summary.json` and a reviewable
`scoreboard-section.md`. After reviewing evidence and paths, append—never
rewrite—the candidate to
`prompt-exports/optimize-content-addressed-codemaps-runs.md`. The explicit
automation path is guarded and append-only:

```bash
python3 Scripts/worktree_startup_live_benchmark.py aggregate \
  ... \
  --append-scoreboard prompt-exports/optimize-content-addressed-codemaps-runs.md \
  --confirm-append-scoreboard
```

The production-enable gate is all-or-nothing:

1. zero file/folder/search/read/selection/codemap/watcher/root-lifecycle
   correctness mismatches;
2. zero eligible projected fallbacks after warmup;
3. projected p95 improves at least 40% over forced-full for root-ready,
   first-search, and first-read;
4. every other latency p95 regresses no more than 5%;
5. absolute peak/final RSS and physical-footprint growth are each no more than
   10%, including width 8 and aged-app cohorts; signed deltas are report-only,
   and missing, zero, negative, or non-finite control baselines fail closed;
6. artifact IDs, cohort/invocation keys, sample ordinals, correlation UUIDs,
   and session UUIDs are unique, one-to-one, and cannot mix reruns; planned
   invocation and sample counts are exact;
7. every documented CPU/RSS, Git, filesystem, actual-route, and fallback field
   is present and valid: availability is explicit; counts are nonnegative
   integers; Git family and priority totals equal command count; filesystem
   operation/item counts and duration are typed and internally consistent;
   RSS/physical-footprint absolutes are positive finite values with coherent
   peaks/deltas; CPU totals, sample count, duration, and average/peak core
   utilization are finite, ranged, and internally consistent;
8. teardown evidence is complete: agents terminal, secondary roots/worktrees
   removed, memory sampling stopped and independently verified, route/settings
   restored or unchanged, diagnostics reset, and the sole planned root restored.

Missing matrix cells, CPU/physical-footprint data, cold main-root evidence, or
correctness evidence yields `incomplete`. Any recorded invalid attempt yields
`fail`; it is never silently excluded from campaign validity. Never infer a gate
from configured route names, untyped text, generic tool failures, or additional
valid samples.

### 100k and 1M synthetic hooks

The routine namespace-manifest scale contract generates 100,000 records and
asserts exact record/read counts, more than 100 initial spill runs, and bounded
buffer bytes:

```bash
make dev-test \
  FILTER=RepoPromptTests.WorkspaceRootNamespaceManifestTests/testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes
```

The opt-in one-million-record version uses the same executable oracle and
resource policy; keep it separate from ordinary root-suite timing:

```bash
REPOPROMPT_NAMESPACE_MANIFEST_SCALE_ENTRY_COUNT=1000000 \
  make dev-test \
  FILTER=RepoPromptTests.WorkspaceRootNamespaceManifestTests/testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes
```

These hooks validate spill/streaming scale, not live Agent Mode latency. The
live 100k/1M workspace campaign still needs the route, resource, correctness,
and teardown thresholds above.

Script-only validation, with no app or CLI calls:

```bash
python3 -m py_compile Scripts/worktree_startup_live_benchmark.py
python3 Scripts/worktree_startup_live_benchmark.py --help
python3 Scripts/worktree_startup_live_benchmark.py create-marker --help
python3 Scripts/worktree_startup_live_benchmark.py self-test
python3 Scripts/worktree_startup_live_benchmark.py self-test --help
python3 Scripts/worktree_startup_live_benchmark.py plan --help
python3 Scripts/worktree_startup_live_benchmark.py record-evidence --help
python3 Scripts/worktree_startup_live_benchmark.py preflight --help
python3 Scripts/worktree_startup_live_benchmark.py run --help
python3 Scripts/worktree_startup_live_benchmark.py smoke --help
python3 Scripts/worktree_startup_live_benchmark.py aggregate --help
python3 Scripts/worktree_startup_live_benchmark.py cleanup --help
```

## Handoff checklist

- Protected contract, plausible defect, chosen layer, and observable oracle.
- Added/renamed/consolidated/removed exact IDs, including complete `old -> new/removed` mappings.
- Surgical ledger update confirmed; curated ledger was not regenerated or overwritten.
- `scenario_count` rationale and before/after affected-suite plus root/provider/repository totals for consolidations.
- Exact focused test, list, ledger verification, style, and guardrail commands with exit results.
- For campaigns only: append-only inventory/baseline/focused/root artifact paths, scoreboard entry, sample validity, and timing comparison.
- Any coverage deliberately omitted, removed, moved to diagnostics, or replaced by a guardrail, with justification.
