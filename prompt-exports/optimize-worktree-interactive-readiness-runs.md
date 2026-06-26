# Worktree Interactive Readiness Optimization Runs

Append-only campaign log. Never rewrite historical rows or delete valid slow
samples. Corrections are new dated entries referencing the superseded entry.
Synthetic fixtures are parser/test evidence only and are never authoritative
baseline samples.

## Target

Primary cohort: fully loaded steady-state real RepoPrompt CE non-worktree main
root in the dedicated `RPCE Search Bench Main 20260618` workspace → fresh
app-managed Agent Mode linked worktree, warm process, width 1.

Primary metric:
`max(first successful direct file_search completion,
first successful direct read_file completion) - bindingTransitionStarted`.

Pass:
- exact `diffSeedServing={"diffSeedServing":1}`;
- empty fallbacks;
- primary p95 at least 30% below same-build forced-full;
- no secondary regression above 10%;
- all correctness, cleanup, resource, and transcript gates pass.

## Frozen environment and provenance

- Campaign plan SHA-256: `<pending>`
- Confirmation plan SHA-256: `<pending>`
- App build SHA: `<pending>`
- CE CLI version/schema hashes: `<pending>`
- Workspace/window/context/root IDs: `<pending>`
- Authoritative root: `/Users/pvncher/Documents/Git/repoprompt-ce-release`
- Fixture classification: real repository; synthetic fixtures non-authoritative
- Commit/tree/blob SHA-256: `<pending>`
- Observed tracked/loaded file count: `<pending>`
- Host model/RAM/macOS: `<pending>`
- Power/thermal/sleep evidence: `<pending>`
- Benchmark artifact root: `<pending>`

## Historical evidence — not iteration 0

| source | route validity | metric | p50 ms | p95 ms | CV | disposition |
|---|---|---|---:|---:|---:|---|
| synthetic production-equivalent | synthetic only | reported total | 3224.305 | 3430.394 | unavailable | historical, not live gate evidence |
| retained synthetic | synthetic only | reported total | 3060.035 | 3332.038 | unavailable | ~2.87% p95 improvement only |
| live ~1996-file forced-full | valid forced-full | materialize→rootReady | 352.287 | 456.622 | unavailable | historical |
| live ~1996-file forced-full | valid forced-full | materialize→first search | 670.437 | 2505.763 | 79–84% tail range | historical |
| live ~1996-file forced-full | valid forced-full | materialize→first read | 792.739 | 2967.240 | 79–84% tail range | historical |
| prior serving attempts | invalid | interactive readiness | — | — | — | not established: base snapshot/catalog/receipt/witness/mixed fallback failures |

Historical search/read p95 values do not establish historical interactive
readiness p95 because per-sample maxima are unavailable.

Warm marker closure at checkpoint `52b69926` is transcript-proven by exactly two
successful `get_code_structure` calls followed by passive tree `Tool.swift +`.
It is correctness evidence, not campaign latency evidence.

## Iterations

| iteration | single change | forced-full artifact | serving artifact | widths/process states | primary values ms | primary p50/p95/CV | serving vs forced p95 | secondary gates | route/correctness | decision |
|---:|---|---|---|---|---|---|---:|---|---|---|
| 0 | DEBUG instrumentation/schema-v5 and baseline only | `<pending>` | `<pending>` | warm width 1 first; 4/8 and aged only after valid serving | `<pending>` | `<pending>` | `<pending>` | `<pending>` | serving not yet established | pending |
| 1 | streamed loaded-root Git authority evidence | `20260626T172258Z-warm-forced-full-w1-75e14e0f` | `20260626T172537Z-warm-projected-w1-1558494c` | warm width 1 only | valid `[]`; invalid forced `[738.472, 871.169, 839.719]` | unavailable / unavailable / unavailable | unavailable | correctness and projected export incomplete | setup reached `diffSeedServing`; exact serving/fallback sample absent | incomplete |
| 2 | narrowed Git worktree mutation lock | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |
| 3 | demand-reserved CodeMap capacity, only if attributed | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |
| 4 | reserved one-variable refinement | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |
| 5 | reserved one-variable refinement | `<pending>` | `<pending>` | same valid matrix | `<pending>` | `<pending>` | `<pending>` | `<pending>` | `<pending>` | pending |

## Per-series retained samples

Append one section per artifact containing all retained values in ordinal order;
p50, p95, and CV; route/fallback maps; root/search/read/codemap/tree/selection,
Git/filesystem/lock/planner/resource evidence; correlation/session/context
identity; raw transcript/direct-probe status; and invalid attempts without
replacement.

## Stop record

- Stop reason: `<gate passed | deterministic diminishing returns | iteration 5 exhausted | incomplete serving baseline | inconclusive>`
- Accepted cumulative changes: `<pending>`
- Rejected/reverted changes: `<pending>`
- Final artifact and evidence paths: `<pending>`

## 2026-06-26 — Iteration 0 baseline attempt (append-only)

### Frozen real-repository provenance

- Workspace: `RPCE Search Bench Main 20260618`
- Window/workspace/context/root IDs: `1` /
  `163E658F-4313-4894-B003-595287E59AE9` /
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` /
  `004BC297-1943-43E6-BE23-5BBF32699F85`
- Authoritative root: `/Users/pvncher/Documents/Git/repoprompt-ce-release`
- Commit OID: `52b69926dd3f5a2e1ee78b89d50ab0711e488bba`
- Observed counts: 2,137 tracked files; 2,120 loaded searchable files
- Final primary/confirmation plan SHA-256 fields:
  `daace6e4c9106227bf669cbdb1cda38da940fecb78db6d9a166126bc549712f5` /
  `<predeclared but unused after invalid projected setup>`
- Exact plan-file SHA-256: `22c3147346334243095633f3beaf8e490008dbfbb47168287a28630dfa9e421e`
- Exact confirmation-plan-file SHA-256:
  `777919e317d0749bd99dc1f96757f4376a59d43d4f021831a8b80b3fa49f2d92`
- App binary SHA-256:
  `3c367ad3ca93fc0a5e73e0a2420ddc0461488bd593edd8002fd9ea78481e5878`
- CLI: `rpce-cli-debug (repoprompt-mcp) 1.0.21`
- Host: `Mac16,7`, 48 GiB RAM, macOS 26.5 (25F71), AC power, battery 80%
- Ownership: dedicated real-repository marker removed after cleanup; no benchmark
  marker remains.

### Preflight

- Final preflight: `/tmp/rpce-worktree-startup/v1/20260626T150906Z-preflight-b252dcb7`
- Earlier valid preflight:
  `/tmp/rpce-worktree-startup/v1/20260626T150710Z-preflight-9091287d`
- Result: passed exact workspace/root/commit/blob/schema scope.
- Frozen read blob SHA-256:
  `fdb8770f38746a62e319cc3b4cef530caad2ada603eb5e0fd66c360bca5cd6ed`

### Forced-full width 1

Final artifact:
`/tmp/rpce-worktree-startup/v1/20260626T151126Z-warm-forced-full-w1-adaf08ea`

- Predeclared: one warmup + five retained.
- Recorded: one invalid warmup; ordinal 2 then terminated on an exact
  `get_code_structure` timeout. No ordinal was replaced.
- Retained primary values: `[]`.
- Primary p50/p95/CV: unavailable / unavailable / unavailable.
- Invalid warmup primary value: `901.150 ms` interactive readiness.
- Invalid warmup component values:
  - materialize→root ready `411.839 ms`
  - materialize→search `901.150 ms`
  - materialize→read `838.398 ms`
  - direct search/read `246.381 / 101.972 ms`, concurrent
  - first/warm codemap `9231.979 / 85.966 ms`
  - passive tree `18648.134 ms`
  - selection `11015.273 ms`
- Actual route/fallback: `{"fullCrawl":1}` / `{}`.
- Git: 20 commands; `579.908 ms` duration; `168.660 ms` queue.
- Filesystem: 1 operation, 1 item, `350.292 ms`.
- Mutation lock: queue `0.001 ms`, held `397.453 ms`, mutation `349.149 ms`,
  post-mutation finalization `30.813 ms`.
- Codemap/tree/selection correctness: codemap returned the exact real
  `WorkspaceRootSeedPlanner` content twice, but the raw result used the intended
  logical-root display plus session-bound worktree scope. The strict direct
  validator rejected logical binding attribution, passive tree did not show the
  required current `+` marker/legend, and selection root attribution was absent.
  The sample is invalid (`content_oracle_mismatch`), not timing evidence.
- Resource session (diagnostic only): 623 samples over 64.6 s; average/peak
  core 120.4%/358.1%; resident baseline/peak/final 332.2/354.7/349.6 MiB;
  physical footprint baseline/peak/final 197.9/217.0/200.7 MiB.
- Cleanup: complete; owned Agent session/worktree removed, route restored,
  memory sampler stopped, scope reset.

Earlier non-replacement setup attempts retained as invalid evidence:

- `/tmp/rpce-worktree-startup/v1/20260626T150744Z-warm-forced-full-w1-aab80d53`
  — follow-on codemap binding validator required the physical rather than logical
  displayed root; zero samples recorded; cleanup complete.
- `/tmp/rpce-worktree-startup/v1/20260626T150939Z-warm-forced-full-w1-5445ff52`
  — passive tree marker gate failed before export; zero samples recorded;
  cleanup complete.

### Projected width 1

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T151309Z-warm-projected-w1-d727c2ef`

- Failed before arming or starting a sample.
- Exact error: `base_snapshot_unavailable`.
- Stage: `discovery_authority_capture`.
- Cause: `git_record_limit_exceeded`.
- Actual route counts: unavailable because route setup failed before start.
- Fallback counts: unavailable because no sample was armed.
- `diffSeedServing` serving baseline: **not established**.
- Cleanup found no owned Agent session/worktree or active memory sampler; scope
  reset succeeded. `restore_route` was false because no route control lease had
  ever been created. The ownership marker was removed separately.

### Correctness and stop decision

- Timing used direct correlated diagnostics and raw structured CLI results;
  assistant prose was not accepted.
- Actual `agent_run` starts occurred in forced-full attempts, but the dedicated
  transcript smoke gate was not reached after projected setup failed. Therefore
  no inference transcript is claimed as passing evidence.
- Widths 4/8 and aged cohorts were not run because width-1 projected serving was
  invalid.
- Confirmation plan was predeclared but not run because there was no valid
  primary series to confirm.
- Iteration 0 decision: **incomplete**. Exact reason: projected setup could not
  prepare a reusable base snapshot (`discovery_authority_capture` /
  `git_record_limit_exceeded`), and forced-full produced zero valid retained
  samples. No optimization or repair was attempted.

## 2026-06-26 — Iteration 0 instrumentation-hardening correction (append-only)

This corrects the preceding preflight provenance; no raw artifact is superseded.

### Exact preflight correction

- `20260626T150906Z-preflight-b252dcb7` belongs to revision-2 plan SHA `bb1e5459275c1756af16a71ab69cac9ac635a838931c726b28461a6943c5d861` (file SHA `16fc77f0afc6992d5f7785fa87d5c740b8640ebf38cfbb33cb57b3f9ab32cb3d`), not the final plan.
- New exact unchanged-final-plan preflight: `/tmp/rpce-worktree-startup/v1/20260626T153947Z-preflight-dba72e60`.
- Final plan field/file SHA: `daace6e4c9106227bf669cbdb1cda38da940fecb78db6d9a166126bc549712f5` / `22c3147346334243095633f3beaf8e490008dbfbb47168287a28630dfa9e421e`; exact marker SHA: `494b00e3f833acd3d4feb52eabfc183b5696f52769ab8d024682916275e86d6c`.
- Preflight proved workspace/context/root `163E658F-4313-4894-B003-595287E59AE9` / `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` / `004BC297-1943-43E6-BE23-5BBF32699F85`, commit `52b69926dd3f5a2e1ee78b89d50ab0711e488bba`, and blob `fdb8770f38746a62e319cc3b4cef530caad2ada603eb5e0fd66c360bca5cd6ed`.

### Width-1 hardening probe

- DEBUG relaunch ticket `adc13aee-d68c-482d-9615-5b71e171033f` exited 0. App/CLI SHA: `6faae945141c20dd8d77f99b11ddf99f2aecd2e7a81728247e14d2e591e2e9f8` / `d11a2c84a56349ba6d7fd6b5145746a08599619df01c4be61f094fdf1c7a84f5`.
- Relaunch loaded the same real root with runtime root UUID `BE7E1E7D-D4A4-4FDB-A3D1-7A3121A25A6E`, 2,121 searchable entries, one crawl, and one watcher. The UUID differs from the frozen plan.
- Artifact `/tmp/rpce-worktree-startup/v1/20260626T154721Z-warm-projected-w1-746449e0` failed closed at `scope mismatch for root_id`, before route control, sampler, arm, worktree, or export. State has zero sessions/worktrees and null control/sampler.
- Samples `[]`; p50/p95/CV unavailable; route/fallback counts unavailable. No serving baseline is claimed.
- Prior projected artifact `/tmp/rpce-worktree-startup/v1/20260626T151309Z-warm-projected-w1-d727c2ef` remains the exact `base_snapshot_unavailable` / `discovery_authority_capture` / `git_record_limit_exceeded` evidence. It was not repaired or retested past the new scope failure.

### Transcript/correlation evidence

- Actual inference `B5CFE3AC-3A5F-4C00-AF78-7F77314B5220` logged exactly one `file_search` then one `read_file` in `/tmp/rpce-hardening-gate-clean-log.txt`. Tool-result elements were absent and same-context direct probes returned `worktree_scope_unavailable`; sentinel prose is rejected and this live gate is incomplete.
- Related raw files: `/tmp/rpce-hardening-gate-clean-start.txt`, `/tmp/rpce-hardening-gate-clean-wait.txt`, `/tmp/rpce-hardening-direct-bind.txt`, `/tmp/rpce-hardening-direct-search.txt`, `/tmp/rpce-hardening-direct-read.txt`, and `/tmp/rpce-current-runtime-snapshot.txt`.
- Focused Swift correlation/boundary test passed (ticket `187ddc6c-73fe-43a2-ba69-ce6a338f551f`). Python py_compile and all 129 harness self-checks passed.

### Decision

Iteration 0 remains **incomplete**. No valid retained forced-full or exact `diffSeedServing` sample exists. Widths 4/8 and aged were not attempted; no optimization, `git_record_limit_exceeded` repair, or frozen-root-UUID repair was attempted.

## 2026-06-26 — Iteration 0 post-relaunch current-root follow-up (append-only)

### Current scope and steady-state proof

- Window/workspace: `1` / `163E658F-4313-4894-B003-595287E59AE9`
  (`RPCE Search Bench Main 20260618`).
- The window listing reported active tab context
  `065F8ED3-433A-4F5F-9E1F-CC2AE2986220`; the dedicated main-root benchmark
  control context used by every exact call was
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783`.
- Current post-relaunch main-root UUID:
  `BE7E1E7D-D4A4-4FDB-A3D1-7A3121A25A6E`.
- Commit: `52b69926dd3f5a2e1ee78b89d50ab0711e488bba`.
- Full root tree: 2,501 lines / 146,085 bytes, untruncated, one root. Exact
  fixed search/read both succeeded before planning. Runtime steady state was
  one crawl, one watcher, no active freshness flight, no queued/applying/
  outstanding publication, and projection generation lag zero. Search/catalog
  counts were 2,120 searchable files and one visible root.
- Raw discovery: `/tmp/rpce-worktree-startup/followup-discovery-20260626`.

### Fresh frozen plans and exact preflights

- Control directory:
  `/tmp/rpce-worktree-startup/followup-20260626T-current-root`.
- Primary plan: `primary-plan.json`; plan/file SHA-256
  `4963cd5aa1a7683ecfb841347c7eef59b6d811dd9fddcafe141d7fcb9a1bd2ce` /
  `e2b82b1591e401f20400de872aa268c7e6c8b47ee39a4fa0f3ba3888eaf5282a`.
- Confirmation plan: `confirmation-plan.json`; plan/file SHA-256
  `26f7375004fa04e8800262628ddcb46bde7d3e90aac652cf022b67eb1a848d23` /
  `84bd2a6ab6b004384a7c309df4fae1fc16cff490fd2307a4d532e383962c6b3e`.
- Both plans froze exactly one excluded warmup plus five retained samples after
  discovery of the current root UUID. Confirmation was not run after the
  mandatory projected-setup stop.
- Primary exact preflight:
  `/tmp/rpce-worktree-startup/v1/20260626T160314Z-preflight-a1b2a919`.
- Confirmation exact preflight:
  `/tmp/rpce-worktree-startup/v1/20260626T160315Z-preflight-f27a2fb7`.
- Both preflights passed the exact window/workspace/context/root, commit,
  tracked blob, schema, gate, and one-root workspace checks.
- Marker SHA-256: `6712a849bdcf656044628a68647e1a64cf77aea297a7804f2143fef86b3ab542`.
- App/CLI SHA-256:
  `6faae945141c20dd8d77f99b11ddf99f2aecd2e7a81728247e14d2e591e2e9f8` /
  `d11a2c84a56349ba6d7fd6b5145746a08599619df01c4be61f094fdf1c7a84f5`.

### Width-1 forced-full, run first

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T160355Z-warm-forced-full-w1-34f593f1`

- Frozen count: one warmup + five retained. Four samples were exported (warmup
  plus ordinals 2–4); ordinal 5 then stopped on exact
  `get_code_structure returned 'timeout', not ready`. No ordinal was replaced.
- Valid retained raw primary values: `[]`.
- Valid retained p50 / p95 / CV: unavailable / unavailable / unavailable.
- Invalid raw diagnostic interactive-readiness values were warmup `724.620 ms`
  and retained ordinals 2–4 `[883.632, 1025.205, 861.304] ms`. These are
  correctness-failed evidence only and are excluded from statistics.
- Every exported sample reported configured `forcedFullCrawl`, actual
  `{"fullCrawl":1}`, and fallback counts `{}`.

| ordinal | class | readiness ms | materialize→root/search/read ms | direct search/read ms | first/warm codemap ms | tree/selection ms | Git count; duration/queue ms | filesystem ms | lock held/mutation/finalize/queue ms |
|---:|---|---:|---|---|---|---|---|---:|---|
| 1 | invalid warmup | 724.620 | 346.712 / 724.620 / 662.523 | 231.227 / 134.488 | 2525.081 / 84.422 | 5894.284 / 10451.255 | 1024; 9396.093 / 8070.324 | 292.819 | 348.446 / 303.987 / 28.237 / 0.001 |
| 2 | invalid retained | 883.632 | 407.602 / 883.632 / 814.031 | 324.122 / 219.741 | 5856.728 / 143.192 | 6105.762 / 10733.949 | 1024; 9503.208 / 8200.793 | 350.215 | 348.741 / 302.168 / 29.411 / 0.002 |
| 3 | invalid retained | 1025.205 | 399.135 / 1025.205 / 958.735 | 396.769 / 293.337 | 6056.859 / 88.492 | 8111.965 / 10760.995 | 1024; 9622.600 / 8241.752 | 350.368 | 343.663 / 296.627 / 29.601 / 0.000 |
| 4 | invalid retained | 861.304 | 375.398 / 861.304 / 794.620 | 328.916 / 226.380 | 6440.314 / 86.824 | 3931.422 / 10944.437 | 1024; 9511.104 / 8197.932 | 320.118 | 381.453 / 332.419 / 30.573 / 0.000 |

- Raw structured direct calls showed exact correlated search success and the
  intended physical `session_worktree`, but read validation failed with
  `read_file expected file content missing`. Both codemap calls returned the
  exact content on ordinals 1–4. Passive tree failed the required exact current
  marker/legend and selection omitted structured `worktree_scope`; every
  exported sample was therefore invalid as `content_oracle_mismatch`.
- Raw evidence is in `samples.ndjson`, `resources.json`, `cleanup.json`, and
  `raw/` under the artifact. In particular, `first-search`, `first-read`,
  `first-codemap`, `warm-codemap`, `passive-tree`, `selection-get`, and
  `export` files were inspected rather than accepting assistant prose.
- Resource session: 1,438 samples over 148.8 s; average/peak core
  121.3%/394.0%; resident baseline/peak/final 362.5/430.5/430.5 MiB;
  physical footprint baseline/peak/final 122.6/187.6/187.6 MiB.

### Width-1 projected/diff-seed, run second

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T160751Z-warm-projected-w1-0606aae2`

- Failed before control acquisition, sampler start, arm, Agent session,
  worktree, or sample export.
- Exact error: `base_snapshot_unavailable`; reason `failed`; stage
  `discovery_authority_capture`; cause `git_record_limit_exceeded`.
- Valid retained raw primary values: `[]`.
- Valid retained p50 / p95 / CV: unavailable / unavailable / unavailable.
- Actual route and fallback counts are unavailable because setup failed before
  a projected sample was armed. Exact `diffSeedServing` remains unestablished.
- Per the frozen stop rule, no width 4/8, aged, confirmation, or dedicated small
  transcript correctness gate was attempted. The forced-full `agent_run`
  starts used actual inference, but their no-tools prompt is not claimed as the
  transcript gate. No assistant prose is accepted as correctness evidence.

### Cleanup and disposition

- Forced-full recorded five owned sessions and five owned app-managed
  worktrees. All sessions reached `completed`; all five worktrees were removed;
  the sampler was ownership-matched and verified stopped; the route was
  restored; diagnostics reset; the DEBUG gate remained enabled; and the main
  workspace returned to its one-root inventory.
- Session deletion was limited to those five exact recorded IDs. The batch and
  subsequent single-ID calls closed their CLI connections after deletion, so
  the call responses themselves are not accepted as success. A fresh
  `list_sessions` returned none of the five IDs; proof is
  `owned-session-cleanup-proof.json` in the control directory. No unrelated
  session was targeted.
- Projected cleanup recorded zero sessions/worktrees, `start_not_attempted` for
  the sampler, `not_acquired` for the route, successful diagnostic reset, and
  restored one-root workspace inventory.
- The ownership marker was unlinked only after its SHA, owner token, workspace
  ID, current root UUID, canonical path, and purpose all matched. Proof:
  `marker-cleanup.json` in the control directory.
- Disposition: **incomplete / fail closed**. Forced-full has zero valid retained
  samples, and projected serving again failed at
  `discovery_authority_capture/git_record_limit_exceeded`. No timing comparison,
  p95 improvement, or serving claim is made. No repair, relaunch, build, test,
  width 4/8, aged run, or commit was attempted.

## 2026-06-26 — Iteration 1 streamed loaded-root Git authority evidence (append-only)

### Attributed implementation and focused validation

- Implemented only the iteration-1 loaded-root Git authority optimization:
  prefix-control evidence and full `ls-tree` inventory are streamed through
  authenticated spill-backed manifests instead of being accumulated under the
  legacy 10,000-record all-or-nothing limit. Memory, record/batch bytes, open
  runs/files, and aggregate spool bytes are bounded; total repository records
  are not capped. Snapshot schema/content domains advanced to v5.
- Exact fail-closed currentness checks remain around authority capture, catalog
  batching, manifest finalization, and admission. Corrupt/truncated manifests,
  stale catalog batches, cancellation, resource exhaustion, sparse/submodule/
  nested/external/ambiguous topology, and unsupported Git evidence still reject
  reuse or fall back to the existing full crawl. Non-Git roots and non-Git
  search/read were not routed through the new representation.
- Focused compile passed: coordinated RepoPrompt product build ticket
  `299fe0bc-8eff-4a47-aba2-1fbc92fc1119`.
- New focused authority suite passed: ticket
  `0dcae8d8-4139-4129-9b2e-04200cdffde2`. It includes a control file after
  10,001 lazy non-control candidates, lazy 100,000 candidate and tree records,
  corruption/cancellation/resource cleanup, and stale-currentness zero-admission
  coverage. The large-record test asserts buffered bytes, open runs, aggregate
  artifact bytes, verified EOF, exact record count, and zero active artifacts
  after lease release without first materializing the logical stream.
- The opt-in 1,000,000 logical candidate/tree-record test passed in `100.489 s`
  with the same bounded assertions. It was run directly with
  `RPCE_RUN_MILLION_RECORD_GIT_AUTHORITY_TESTS=1` because conductor does not
  forward that opt-in environment key.
- Touched-path compatibility tests passed: seed planner ticket
  `30490418-bfb6-4832-b02a-b214d28745d9`, initialization API
  `d9115991-...`, authority `bc1fd509-...`, projected path search
  `4c2f152a-...`, and creation receipt final rerun
  `d1a89a6d-f7dc-4453-a8b0-f4b69bee7aee`. No release build, full suite, lint,
  benchmark-gate change, or unrelated repair was performed.

### Post-relaunch frozen scope and preflight

- Coordinated DEBUG relaunch ticket
  `987de240-65ad-4752-922f-89f5146d5650` exited 0; visible app PID `71554`.
  App/CLI SHA-256:
  `a28a4c93e4193cd2fbd2a4a62bb73a8c670436996ebc1b748093627c297ed32a` /
  `457eed710e7537a06e83ba129ad085e41d827c6f857066bea6c757e3f7b7acf6`.
  CLI version: `repoprompt_ce_cli_debug (repoprompt-mcp) 1.0.21`.
- Window/workspace/context/current root: `1` /
  `163E658F-4313-4894-B003-595287E59AE9` /
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` /
  `54F3CDD8-BC02-4863-9B5C-24A7A88ADFA2`.
- Real root `/Users/pvncher/Documents/Git/repoprompt-ce-release`, commit
  `8103b122f23f1087ada2e0a5db16eb69feef2fc3`, 2,138 tracked files.
- Primary/confirmation plans:
  `/tmp/rpce-worktree-startup/iteration1-20260626/primary-plan.json` and
  `confirmation-plan.json`. Plan SHA fields:
  `818759584a3e38237fc2e8c99781750b1194d5f16dc2e476fe87db2fa112a385` /
  `7cc2fa332e71902f1c9d5fd70b32a32cdaed725498225ab3f489259daa84fa23`;
  file SHA-256:
  `7d7d62fc09cbc1dff1ecd92dbc64c634bc7e3ae84a774f54257fe23f2278538e` /
  `bd166647033be89fd6d1701fda16b33f67ee5aeb4919667256f5a5bb31918eeb`.
- Exact post-relaunch preflights passed:
  `/tmp/rpce-worktree-startup/v1/20260626T172215Z-preflight-10bb0b9a` and
  `/tmp/rpce-worktree-startup/v1/20260626T172216Z-preflight-e5a548f7`.
  Both froze the same scope/commit and read blob
  `a2133dce4c6c67cfdfaa47173e2ce03c8b8f818b486eadf985ba8fa7b5e170e8`.
- Host: `Mac16,7`, 48 GiB RAM, macOS 26.5 (25F71), AC power, battery 80%.

### Width-1 forced-full, run first

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T172258Z-warm-forced-full-w1-75e14e0f`

- Frozen count: one warmup + five retained. Three samples were exported
  (warmup plus ordinals 2–3); ordinal 4 then stopped on exact
  `get_code_structure returned 'timeout', not ready`. No ordinal was replaced.
- Valid retained raw primary values: `[]`.
- Valid retained p50 / p95 / CV: unavailable / unavailable / unavailable.
- Invalid raw diagnostic readiness values were warmup `738.472 ms` and retained
  `[871.169, 839.719] ms`. For transparency only, that excluded two-value
  diagnostic series has p50 `855.444 ms`, nearest-rank p95 `871.169 ms`, and
  population CV `0.018382`; it is **not** retained performance evidence.
- Every exported sample reported actual route/fallback
  `{"fullCrawl":1}` / `{}` and was invalid as `content_oracle_mismatch`.

| ordinal | class | readiness ms | materialize→root/search/read ms | direct search/read ms | first/warm codemap ms | tree/selection ms | Git count; duration/queue ms | filesystem ms | lock held/mutation/finalize/queue ms |
|---:|---|---:|---|---|---|---|---|---:|---|
| 1 | invalid warmup | 738.472 | 338.446 / 738.472 / 698.924 | 136.332 / 135.701 | 4168.747 / 91.569 | 8168.621 / 10519.256 | 1024; 10234.858 / 9128.258 | 281.798 | 384.345 / 337.819 / 29.598 / 0.002 |
| 2 | invalid retained | 871.169 | 381.561 / 871.169 / 791.191 | 243.268 / 96.117 | 4906.019 / 84.144 | 10937.180 / 10728.058 | 1024; 10190.607 / 9240.803 | 323.752 | 332.766 / 285.996 / 30.118 / 0.000 |
| 3 | invalid retained | 839.719 | 352.772 / 839.719 / 760.905 | 248.653 / 93.897 | 7345.174 / 97.974 | 5571.362 / 10835.733 | 1024; 10286.848 / 9236.798 | 299.882 | 386.359 / 342.375 / 27.350 / 0.000 |

- Phase attribution: interactive readiness was dominated after root readiness by
  first search; Git diagnostic work was almost entirely queued
  (`9.13–9.24 s` of `10.19–10.29 s`) and attributed to 896–897 codemap-authority
  plus 127–128 tree-resolution commands. Codemap demand recorded 92 requests in
  warmup and 68 in each retained diagnostic sample; no codemap builds or permit
  waits were attributed. Content-read admission wait/execution stayed below
  `0.010 / 0.262 ms`.
- Secondary correctness gates failed exactly as before the optimization: direct
  read reported `read_file expected file content missing`, passive tree omitted
  the required exact current marker/legend, and selection omitted structured
  `worktree_scope`; search and both codemap calls returned expected content.
  These are out-of-scope validator/codemap readiness issues and were not repaired.
- Resource session: 1,184 samples over 122.3 s; average/peak core
  119.0%/346.4%; resident baseline/peak/final 316.2/379.5/379.5 MiB
  (peak delta 63.3 MiB); physical footprint baseline/peak/final
  115.4/176.1/176.1 MiB (peak delta 60.6 MiB); session CPU 145,456.1 ms.

### Width-1 projected/diff-seed, run second

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T172537Z-warm-projected-w1-1558494c`

- The iteration-0 blocker is removed: projected route setup successfully
  prepared base snapshot identity
  `bcf385c2e8163e4000272f45a8b90139e204da1ce6a9dfade4f59c0a4fe23053`
  and returned route `diffSeedServing`. There was no
  `discovery_authority_capture/git_record_limit_exceeded`.
- The first sample then stopped on exact
  `get_code_structure returned 'timeout', not ready` before export. Recorded
  samples `[]`; valid retained primary values `[]`; p50/p95/CV unavailable.
- Because no sample export exists, actual per-sample route counts and fallback
  counts are unavailable. Setup route `diffSeedServing` is not accepted as proof
  of the required exact `{"diffSeedServing":1}` / `{}` serving series.
- Per the frozen stop rule, no replacement, confirmation, width 4/8, aged, or
  additional repair was attempted.
- Resource session: 137 samples over 14.1 s; average/peak core
  117.1%/346.8%; resident baseline/peak/final 496.0/508.1/508.0 MiB
  (peak delta 12.1 MiB); physical footprint baseline/peak/final
  187.9/203.0/202.9 MiB (peak delta 15.1 MiB); session CPU 16,531.8 ms.

### Cleanup, artifacts, and recommendation

- Both original run summaries recorded `cleanup_complete: true`. State and raw
  cleanup calls prove all five owned Agent sessions terminal, all five owned
  worktrees removed, both memory samplers stopped, routes restored, diagnostics
  reset, and the one-root workspace restored. The raw proof remains under each
  artifact (`raw/`, `state.json`, `resources.json`, and `samples.ndjson`).
- A later explicit idempotence recheck rewrote the forced-full `cleanup.json`;
  it correctly refused to re-delete the already-absent worktrees because a live
  session/worktree relationship could no longer be proven, while independently
  verifying sampler stopped, route restored, diagnostics reset, and roots
  restored. The pre-recheck proof remains in raw calls `0097`–`0104` and
  `state.json`; the projected original `cleanup.json` was unchanged.
- The dedicated real-root ownership marker was removed only after SHA, owner
  token, workspace/root IDs, canonical path, and purpose all matched. Proof:
  `/tmp/rpce-worktree-startup/iteration1-20260626/marker-cleanup.json`.
- Recommendation: **do not retain from current measurement; revert unless the
  independent reviewer explicitly accepts another measurement cycle**. The
  attributed optimization clears the 10,000-record authority blocker and its
  focused boundedness/fail-closed tests pass, but the mandatory valid projected
  serving cohort, correctness gates, p95 improvement, and memory-regression
  comparison were not established. No commit was created.

## 2026-06-26 — Iteration 1 scoreboard-row correction (append-only)

The top iteration-1 summary row previously named a planned
`sparse/delta-proportional seed plan`, which was not the implemented change.
It now names the actual single change, **streamed loaded-root Git authority
evidence**, points to the recorded forced-full and projected artifacts, and
marks the measurement **incomplete**. This correction changes only the campaign
index row; it does not replace or reinterpret any raw sample or appended
iteration-1 measurement detail above.

## 2026-06-26 — Oracle iteration-1 disposition (append-only)

- Oracle chat `readiness-optimization-66CC5D` decision: **RETAIN iteration 1**.
- This retains the single streamed loaded-root Git authority evidence change;
  it is not a performance-gate pass and does not reinterpret the invalid prior
  timing ordinals. The implementation removed the attributed 10,000-record
  authority blocker, retained fail-closed behavior, and passed its focused
  boundedness/currentness evidence.
- The prior live run could not decide primary performance because the harness
  coupled completed root/search/read timing to codemap/tree/selection follow-on
  acceptance. The approved measurement-support correction is to preserve a
  correlation-bound `primary_performance` result independently while keeping
  failed `follow_on_acceptance` visible and campaign-blocking.
- Campaign status remains **incomplete** until a fresh same-build forced-full
  and projected one-plus-five width-1 series establishes valid primary values,
  exact routes with empty fallbacks, separate follow-on status, resource and
  cleanup proof, and any required high-CV confirmation. No production
  scheduling, Git locking, seed planning, codemap behavior, or threshold change
  is authorized by this disposition.

## 2026-06-26 — Iteration-1 measurement-support rerun (append-only)

### Frozen build, scope, plans, and preflights

- Single approved coordinated relaunch: ticket
  `7063e284-c1c0-44a6-b660-f46ea70692d2`, PID `45589`.
- Build/checkout identity: CLI SHA-256
  `4fdd50df7891d354d9ea3cfcd4f447e8d028e458a8f451f2965c2fa1500873d8`,
  HEAD `be61584899ed2ef5623817b2ad80815c13e4cbeb`, 2,141 tracked files.
- Window/workspace/control-context/current-root:
  `1` / `163E658F-4313-4894-B003-595287E59AE9` /
  `E7BC2FDA-0CBD-4DE9-9C94-C31984E5F783` /
  `8377314A-3965-414D-A5A4-BFCE60810763`. Runtime showed the fully loaded
  real root current with no session-worktree owners.
- Fresh primary/confirmation plans:
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/primary-plan.json`
  (`dea1b3b16557a6d13dfba7b46c16184485355ab0884ca4deeab704e1e198d367`)
  and `confirmation-plan.json`
  (`bb46ca42c3c083719a6cfed0cf74fdc257f473009739d7ba29d7ab0d7d5d550b`).
  Both used search marker `WorkspaceRootSeedPlanner`, first-80-line read marker
  `import CryptoKit`, and read blob SHA-256
  `72df72ed69de7c24a1efbdfa7ffee41f0b32815b5b3ec303c95dc1c0bb7a5aba`.
- Fresh preflights passed at
  `/tmp/rpce-worktree-startup/v1/20260626T182307Z-preflight-ef10ec53`
  and `/tmp/rpce-worktree-startup/v1/20260626T182308Z-preflight-d374efd7`.

### Forced-full primary performance and separate follow-on status

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T182344Z-warm-forced-full-w1-c7e4f414`

- One excluded warmup plus all five retained ordinals completed; no replacement
  or retry occurred. Corrected primary revalidation is preserved separately at
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/forced-full-primary-revalidation.json`.
- Retained primary raw values: `[898.364, 1021.922, 972.808, 946.328,
  866.379] ms`.
- Primary p50 / nearest-rank p95 / population CV:
  `946.328 ms` / `1021.922 ms` / `0.058147`.
- Warmup primary value: `726.572 ms` (excluded).
- Every checkpoint independently passed correlation/session/child-context and
  frozen-scope identity, build/invocation/ordinal, ordered root/search/read
  boundaries, direct structured search+read logical/physical worktree binding,
  committed path/content, terminal receipt, actual route `{"fullCrawl":1}`,
  `{}` fallbacks, resource evidence, and cleanup.
- The original artifact summary recorded primary invalid because the first
  harness revision compared the diagnostic's frozen control-scope context to
  the separate child context and required the non-live sampler spelling
  `physical_footprint_available`. The immutable checkpoints/resources were
  revalidated only after correcting those two validators; no ordinal or raw
  value was rewritten.
- `follow_on_acceptance`: **failed for all six attempts** and remains
  campaign-blocking. Passive tree omitted the required exact current
  marker/legend and selection evidence omitted structured `worktree_scope`;
  the initial collector also mislabeled successful codemap evidence until its
  success default was corrected. Final diagnostic reason was
  `content_oracle_mismatch`. Thus these valid primary values do not make the
  campaign acceptable.
- Resource session: 2,352 samples over 243.4 s; average/peak core
  123.2%/370.1%; resident baseline/peak/final 306.2/390.1/390.1 MiB
  (peak/retained delta 83.9 MiB); physical footprint baseline/peak/final
  117.8/193.3/193.3 MiB (peak/retained delta 75.5 MiB); CPU 299,833.7 ms.

### Projected primary/follow-on status and confirmation rule

Artifact:
`/tmp/rpce-worktree-startup/v1/20260626T183107Z-warm-projected-w1-79fadf26`

- The single predeclared projected invocation timed out after 300 seconds while
  awaiting correlation-scoped `set_flags`. No sample, route, fallback, or
  primary value was produced; acquired session/worktree/resource counts were
  zero and cleanup completed. It was not retried or replaced.
- Projected retained primary raw values: `[]`; p50/p95/CV unavailable.
  Therefore no forced-full/projected improvement claim is possible.
- The predeclared confirmation plan was not run: projected primary CV does not
  exist, so the `>50%` confirmation trigger cannot be evaluated. Series were
  not pooled.

### Transcript/direct-probe smoke and cleanup

- Smoke artifact:
  `/tmp/rpce-worktree-startup/v1/20260626T183642Z-correctness-smoke-4bed38a5`.
  The run timed out after 300 seconds at watcher `apply_edits`, so it is failed
  evidence. The completed parent emitted only eight alternating calls and no
  paired result events; direct structured search passed exact logical/physical
  scope, while direct read lacked unambiguous path attribution. Evidence:
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/smoke-transcript-direct-probe-evidence.json`.
- Both smoke-owned sessions are terminal, the owned parent worktree/branch and
  temporary roots/directories are absent, and raw workspace inventory again
  shows the sole real root. Forced-full and projected cleanup were complete;
  the dedicated diagnostic scope was reset. The exact ownership marker was
  deleted only after purpose/path/workspace/root/owner verification. Proof:
  `/tmp/rpce-worktree-startup/iteration1-measurement-split-20260626T182119Z/final-owned-cleanup-proof.json`.
- Final campaign disposition: **incomplete / fail closed**. Iteration 1 remains
  retained per the Oracle disposition above, but projected primary performance,
  all follow-on acceptance, transcript/direct-probe smoke, and the same-build
  comparison are not established.

## Iteration 1 measurement-support P1 closure correction — 2026-06-26

- Correction to the projected wording above: the 300-second `set_flags`
  timeout was **scope-bound and pre-correlation**, not correlation-scoped. No
  benchmark arm token/correlation was established and no sample, route,
  fallback, or primary value was produced. This wording correction does not
  change the incomplete/fail-closed campaign disposition.
- Reproducible offline primary revalidation provenance is persisted at
  `prompt-exports/worktree-readiness-iteration1-forced-full-revalidation-provenance.json`.
  It records SHA-256 hashes for the frozen plan, artifact plan, summary,
  `samples.ndjson`, resources, cleanup, every source record, and every primary
  checkpoint; validator source SHA-256
  `1ce57f9421137aacc5f0140eae183ea27edf7540b372b9c4c9e7ae73579eef85`
  at validator version 1; and the exact offline command/cwd.
- Source and revalidated retained values are independently recorded as the
  unchanged ordered list `[898.364, 1021.922, 972.808, 946.328, 866.379] ms`;
  the excluded warmup remains `[726.572] ms`. Six unique
  correlation/session identities, exact ordinals 1–6, matching source and
  revalidated checkpoint hashes, exact artifact identity, valid resources,
  and complete cleanup prove the values were neither rewritten nor mixed.
- The harness now fails primary validity for either a false recorded concurrent
  outcome/mark failure or non-overlapping search/read intervals; applies an
  exact single-terminal receipt oracle; and fails follow-on acceptance closed
  on incomplete typed operation/mark/failure inventories or selection
  completion before selection-get. Follow-on failure remains visible and
  campaign-blocking without erasing a valid primary value.
- Closure validation was limited to
  `python3 -m py_compile Scripts/worktree_startup_live_benchmark.py` and
  `python3 Scripts/worktree_startup_live_benchmark.py self-test`; both passed,
  including sequential-operation, receipt, follow-on totalization, provenance,
  cleanup, and unchanged high-CV confirmation-policy cases. No live run,
  relaunch, production edit, broad test, retry/replacement, or commit occurred.
- Oracle iteration-1 decision remains **RETAIN**. Work stops here for independent
  re-review; campaign acceptance remains incomplete because follow-ons and the
  projected comparison are not established.
