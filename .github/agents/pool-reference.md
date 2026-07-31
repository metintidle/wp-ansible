# Worker pool reference (read on demand)

Static reference data for the orchestrator. **Not resident in the orchestrator
prompt** — `read` this only when you need exact per-token costs (break-even
math), a ceiling's provenance, the index-refresh commands, or the derivations
behind a rule. The compact routing table and all decision rules live in
`orchestrator.agent.md`.

## Rationale & worked examples (moved out of the resident prompt)

These justify rules stated tersely in `orchestrator.agent.md`; consult when a
rule needs defending or re-deriving, never re-paste into reports.

- **Attachment trap example**: a ~50K-token HTML file attached over 29
  requests is ~1.4M input tokens for one file. **Double-carry example**:
  `read`-ing ranges of an already-attached 196KB file paid for a second full
  copy on every later request — ~45% of a 3.2M-token session.
- **Triangular batch cost**: at N=24 (turns≈48) the `turns×(turns+1)/2`
  factor is 1,176 — ~400× a flat ×3 estimate. This is how a "few thousand
  tokens per file" chunk blows a TPM ceiling.
- **Throughput ceilings (Little's law, 5K working set ≈ 20K load/chunk)**:
  cheap-coder-kimi ~35 code chunks/min (unconfirmed ceiling);
  cheap-generalist-kimi ~350 reasoning chunks/min (confirmed) — code
  throughput saturates far sooner than reasoning throughput.
- **Uniform chunk sizes (largest ≤2× smallest)**: variance stalls the wave
  (Kingman's formula — wait time grows with variability, not just load).
- **Gated review economics**: a cheap-generalist-kimi diff review is ~$0.25 —
  cheap as an escalation gate, wasteful as a routine step.
- **Arch-cache motivation**: `list_projects` + `get_architecture` at session
  start were two full-context round-trips (~100K tokens each at observed
  session sizes) for tiny outputs; the cache file collapses them to one small
  `read` + one `index_status`.
- **Minimal-output query discipline motivation**: a `search_graph` with
  `limit: 20` returning full node JSON rides every later request of the
  session; filtering by `label`/`name_pattern`/`file_pattern` and consuming
  only `name`/`file_path`/line fields keeps the resident copy near-zero. Same
  for `query_graph`: `RETURN f` drags whole nodes; `RETURN f.name,
  f.file_path LIMIT 10` returns exactly what routing needs.
- **Discovery-quarantine motivation (measured 2026-07-19, session logs)**:
  one session's resident MCP output totaled ~44KB ≈ 11K tokens
  (`get_architecture` alone 13KB ≈ 3.3K); over ~30 later turns that is
  ~300K+ re-billed input for data consulted once. Observed responses are also
  **double-encoded** — the same payload arrives once as raw JSON and again
  pretty-printed (2–3× the data, plus 16-digit float ranks and a repeated
  qualified-name prefix on every hit). A server-side fix (single compact
  encoding + field selection) would halve every MCP result pool-wide; until
  then the scout quarantine keeps fat results out of the orchestrator's
  resident context entirely.

## Full worker table — costs, ceilings, provenance

| Worker | Model | Ctx | Limits | Per-task budget | $ in / out per 1M | Notes |
|---|---|---|---|---|---|---|
| cheap-coder-kimi | gpt-5.1-codex-mini | 400K | ~1M TPM / ~1,000 RPM (**UNCONFIRMED** estimate) | ≤5K working set | 0.25 (0.03 cached) / 2.00 | Cheapest coder. Azure-panel figures not yet confirmed — verify before trusting the ceiling |
| cheap-generalist-kimi | gpt-5-mini | 400K | 10M TPM / 10,000 RPM | ≤5K working set | 0.25 (0.03 cached) / 2.00 | Cheapest general worker AND highest-throughput cheap tier (beats mid-bulk-deepseek on both TPM and RPM). Confirmed via Azure panel |
| mid-bulk-deepseek | gpt-5.1-codex | 400K | 5M TPM / 5,000 RPM | unbounded | 1.82 (0.19 cached) / 14.50 | Code-specialized overflow above cheap-coder-kimi's RPM — NOT a cheap default. Confirmed via Azure panel |
| premium-coder-codex | gpt-5.2-codex | 400K | 10M TPM / 100,000 RPM | unbounded | 2.54 (0.26 cached) / 20.29 | Top coder, latency-critical, batch sub-coordinator, terminal code+reasoning backstop. By far the highest RPM in the pool. Confirmed via Azure panel |
| cheap-reasoner-oss | gpt-oss-120b | 300K | 5M TPM / 5,000 RPM | unbounded | 0.15 (N/A cached) / 0.60 | Dedicated hard-reasoning tier. Cheapest worker on both input and output by a wide margin. Not code-specialized (open-weight general reasoner, not a codex variant) — not on the code ladder. Confirmed via Azure panel |
| mid-frame-motion-recreator | o3 | 200K | 200K input / 100K output | 1 frame-set (5 images) + 1 composition file | 2.00 (0.50 cached) / 8.00 | Only vision worker. Chosen over cheaper Grok-4.3 ($1.25/$2.50) — this is fine-grained visual reasoning, not image description. GA lifecycle |
| free-researcher-nvidia | deepseek-v4-pro | ~130KB hard cap (not token-denominated) | 40 RPM, hard cap | 1 fast-path chunk (≤2 small files) | $0 (free tier, NVIDIA NIM — not Azure-priced) | Pure coding worker, no web-access tools. Only for a chunk that is BOTH fast-path-shaped AND under the 40 RPM / ~130KB caps. Never the sized code ladder or any batch wave |
| free-synth-gemini | gemini-3-flash | 1.1M | 10 RPM / 1,500 RPD, hard cap | 1 accumulated batch (pre-built bundle only) | $0 (free tier — not Azure-priced) | Largest context, tightest request budget. One-shot batch synthesizer over a pre-aggregated bundle — never an explorer, never per-item-judgment batches |

**Confirmation provenance:** mid-bulk-deepseek / cheap-generalist-kimi / premium-coder-codex
confirmed via Azure-panel deployment screenshot (Nov 7, 2025); cheap-reasoner-oss
confirmed via Azure panel (Jul 17, 2026); orchestrator's own gpt-5.6-terra
confirmed via Azure panel (Jul 17, 2026: 10M TPM / 10,000 RPM, 1M ctx ~922K
in / 128K out, $2.50 in / $15 out short-context, cached $0.25, cache writes
$3.125 — **pricing DOUBLES to $5 in / $22.50 out past the short-context
threshold**). cheap-coder-kimi's figures remain the earlier generic-tier estimate,
still unconfirmed.

## Free & flat band — caps and provenance (added 2026-07-19)

User-provided figures; none Azure-panel confirmed. Model strings in the agent
files are picker display names — **verify each against the model picker on
first dispatch** and correct the agent file if the deployment id differs.

| Worker | Model | Ctx | Cap | Provenance |
|---|---|---|---|---|
| free-scout-flash | DeepSeek V4 Flash Free (OpenCode Zen) | 200K | free tier, caps unpublished | OpenCode Zen panel, 2026-07-19 |
| free-coder-north | North Mini Code Free (OpenCode Zen) | 256K | free tier, caps unpublished | same |
| free-bigctx-nemotron | Nemotron 3 Ultra Free (OpenCode Zen) | 1M | free tier, caps unpublished | same |
| free-reviewer-pickle | Big Pickle (OpenCode Zen) | 200K | **200 requests / 5 hours** (spans sessions) | user-confirmed 2026-07-19 |
| free-vision-mimo | MiMo V2.5 Free (OpenCode Zen) | 200K, vision | free tier, caps unpublished | OpenCode Zen panel, 2026-07-19 |
| flat-coder-glm | GLM-5.2 (Z.AI) | 1M | **10 concurrent in-flight**, account-wide | Z.AI limits via user, 2026-07-19 |
| flat-generalist-glm | GLM-4-Plus (Z.AI) | ~128K (**UNVERIFIED** — not on the observed picker list) | **20 concurrent in-flight**, account-wide | Z.AI limits via user, 2026-07-19 |

- **Z.AI limits are concurrency, not RPM/TPM**: a limit of N means N
  simultaneous in-flight requests; tokens are unmetered on the flat plan.
  Both GLM workers draw on one account — apply the 0.7× headroom rule to the
  combined in-flight count per model, and remember every agentic worker holds
  ~1 slot for its whole run.
- **Free-first break-even**: with c_free = 0, `E = c_cheap + (1−p)·c_strong`
  degenerates — any p > 0 wins on price, so the binding tests are shape-fit
  and cap knowledge (probe-one), never cost. A free miss still costs latency
  plus one re-dispatch; that is why probe-one exists.
- **Bench spares**: Hy3 Free (190K) and any OpenCode Zen free model without a
  worker file — promote one by copying the nearest agent file if a band tier
  is retired. Big Pickle's 5-hour window is rolling and shared with any
  other Big Pickle use, so treat its remaining budget as unknown-but-small
  at session start.
- Probe-one telemetry goes in worker-stats.json like any tally
  (`rate_limited` records cap-hits).

## Cost ratios that drive break-even routing

- Cheapest by role: cheap-coder-kimi (code) and cheap-generalist-kimi (reason/read/write),
  both $0.25 / $2.00. cheap-reasoner-oss undercuts both ($0.15 / $0.60) but is
  reasoning-ladder only, not a first-line default.
- mid-bulk-deepseek output ≈ **7×** cheap-coder-kimi (14.50 / 2.00).
- premium-coder-codex output ≈ **1.4×** mid-bulk-deepseek (20.29 / 14.50), both codex-tier —
  so mid-bulk-deepseek pays for itself over premium-coder-codex even below a ~72% success
  rate whenever RPM is not the binding constraint.
- premium-coder-codex output is $20.29/1M — always demand diffs and terse reports from
  it, and keep a byte-for-byte stable brief preamble per worker to earn
  cached-input pricing pool-wide.

## Pool-shape facts (why the ladders are role-based, not capacity-based)

- cheap-generalist-kimi is strictly better than mid-bulk-deepseek on cost AND capacity
  (10M/10,000 vs 5M/5,000). The only reason to pick mid-bulk-deepseek is code
  specialization (gpt-5.1-codex vs gpt-5-mini). So reasoning/general work stays
  on cheap-generalist-kimi almost indefinitely; code work ladders
  cheap-coder-kimi → mid-bulk-deepseek → premium-coder-codex.
- mid-bulk-deepseek's 5,000 RPM is 20× short of premium-coder-codex's 100,000 — different
  throughput classes. premium-coder-codex is the only worker that can absorb a wave
  >5,000 requests/min, so very wide batches route straight to it on capacity
  grounds regardless of cost.
- No **paid ladder** worker holds a ~1M window (the old 1M Azure
  DeepSeek-V4-Flash is gone; text workers cap at 400K, cheap-reasoner-oss at
  300K). Since 2026-07-19, ~1M windows exist only in the free/flat band
  (free-bigctx-nemotron 1M, free-synth-gemini 1.1M, flat-coder-glm 1M) and
  only for single-dispatch bundle/hold shapes. Name-collision warning:
  free-researcher-nvidia's deepseek-v4-pro is a distinct free NIM deployment
  with a ~130KB hard cap, and free-scout-flash's "DeepSeek V4 Flash Free"
  (OpenCode Zen, 200K) is yet another distinct deployment — neither is the
  old Azure 1M worker.

## Reasoning-tier history (context only — no per-turn decision value)

The former reasoner-grok slot sat empty after every replacement dead-ended
(o4-mini, o3-mini, GPT-4.1-mini all deprecated; an early gpt-oss-120b attempt
was fine-tuning-only with no direct-inference path). gpt-oss-120b now has a
genuine Standard (pay-as-you-go) deployment — 300K ctx, 5M TPM, 5,000 RPM,
$0.15 / $0.60 — and is the current cheap-reasoner-oss. (The old fine-tuning-only path
still exists separately as "GPT OSS 20B" in the fine-tuning pricing tier — a
different, smaller model; don't confuse the two.)

## Dependency graph — no static snapshot, no hardcoded project

This agent config is reused across multiple projects (confirmed via
`list_projects`: at least five, including this one). **Never hardcode a
project name or a subdirectory like a source-tree name anywhere in this pool's
files or briefs.** Resolve the active project's `name` and `root_path` fresh
from `list_projects` every session — see orchestrator.agent.md's Mandatory
codebase-memory workflow.

The old design here ran `madge` for a file-level import graph and a custom
`task-partition.js` script to classify it into hub/coupled/independent groups,
refreshed as static snapshots. **That pipeline is superseded**: `get_graph_schema`
confirms the indexed codebase-memory-mcp graph already carries `File`/`Module`
nodes and an `IMPORTS` edge (with `local_name`), plus containment edges — a
superset of what `madge` produced, live and queryable per-project with no
refresh step and no path to hardcode. Use `query_graph` for hub/coupled/
independent classification instead (see orchestrator.agent.md's "Codebase
graph as the dependency index"). If a future project's indexed graph turns out
not to carry `IMPORTS` edges (check via `get_graph_schema` for that project
before assuming), `madge` is a reasonable per-project fallback — but treat that
as an exception to verify, not the default.

**Exact per-file token counts have no graph equivalent** (no token-count
property exists on any indexed node label). `repomix` is installed globally
on this machine (`npm install -g repomix`, confirmed 2026-07-18 — user opted
for global over per-project so it's available across every project without
setup) and is the default way to get tighter-than-chars÷4 sizing. **Neither
you nor any worker in this pool has a shell-execution tool** — this is always
something to tell the user to run themselves, exactly like the graph
re-index case below, never something you can invoke. Give them the command
targeting the active project's `root_path` (from `list_projects` — never a
hardcoded path); **the target directory must be a positional argument placed
before `--token-count-tree`**, not after — that flag takes an optional
numeric threshold and will otherwise swallow a following path as an invalid
threshold value instead of treating it as the directory.

**Never point repomix at `root_path` bare, with no `--include` filter.**
Confirmed by testing (2026-07-18, this project): with no filter it packs
*everything* not gitignored — docs, data files, its own previous output —
not just code. One `.csv` data file alone hit 197K tokens and the unfiltered
run pulled in 588 files; a code-only run of the same project was 86 files.
Repomix itself has no concept of "code file" — get that signal from the
codebase-memory-mcp graph instead of guessing a language-extension list,
since it already parsed this exact project and knows which extensions
produced real symbols:

    query_graph(project, "MATCH (f:File)-[:DEFINES]->(s:Function) RETURN DISTINCT f.extension AS ext")

(repeat for `:Class`, `:Method`, `:Interface` if the first comes back sparse —
this Cypher-like engine doesn't reliably support an `OR` across labels in one
query). Union the distinct extensions into an `--include` glob:

    repomix "<root_path>" --include "**/*.ts,**/*.py,**/*.cjs,**/*.mjs" --token-count-tree -o /tmp/repomix-throwaway.xml && rm -f /tmp/repomix-throwaway.xml

Tell the user this two-step recipe (graph query for the extension set, then
the scoped repomix command) rather than a single command — the extension set
is genuinely project-specific and must come from that project's own graph,
never a hardcoded or assumed language list.

`--token-count-tree` prints the per-file/per-folder breakdown to the console
as it runs (that's the sizing data you want) — the `-o` output file is the
full packed repo content, which for sizing purposes only you can discard
immediately after. Fall back to a project-local, version-pinned install
(`npx repomix ...`, only if that project's own `package.json` declares
`repomix` as a devDependency) when a project needs a specific pinned version
for reproducibility — global is the default, npx-local is the exception, not
the other way around. Treat any resulting count as a point-in-time snapshot,
possibly stale the moment the repo changes.

If `index_status` shows the graph stale relative to HEAD, tell the user to
re-index — you have no `index_repository` tool.

## worker-stats.json schema (E1 — durable success tally)

`.github/agents/worker-stats.json` persists the per-(worker, task-type) tally
that drives break-even routing across sessions. Shape:

    { "workers": { "<worker>": { "<task-type>": {
        "attempts": int, "successes": int, "over_cap": int, "rate_limited": int
    } } } }

`task-type` is a coarse label you choose consistently (e.g. `code:styling`,
`code:concurrency`, `reason:architecture`, `review:ui`). You are read-only, so
you cannot write this file yourself — read it at session start to seed `p`, keep
the running tally in-context during the session, and at the Deliver step
dispatch a single cheap-coder-kimi edit to merge the session's deltas in (one edit, no
reads), but only when an outcome materially changed (new task-type, or a `p`
that crossed a break-even threshold).
