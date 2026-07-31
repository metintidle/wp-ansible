# Architecture cache

Per-project snapshots of `list_projects` + `get_architecture` identity, so the
orchestrator starts a session with one small `read` + one `index_status`
instead of two full-context MCP round-trips. The read-first protocol itself
lives in `orchestrator.agent.md` (Codebase-memory workflow) — this README is
only the format spec and refresh brief; the orchestrator does not read it at
session start.

## Format

- One file per project: `<project-id>.md`, where `<project-id>` is exactly the
  `name` field `list_projects` returns. **`INDEX.md` maps working directory →
  project id and is the only lookup** — the id is a slug of the *indexing
  machine's* `root_path`, which frequently differs from the working tree
  (a `D:\proj` index against a `/home/x/proj` tree yields `D-proj`). Deriving
  the id from the cwd produces a file nothing will ever hit.
- **Hard cap: ≤25 lines total.** One YAML header (`project`, `root_path`,
  `generated`, `graph_signature` nodes/edges, `git`), then a handful of
  bullets: stack + rough file counts, package layout, any stable hand-verified
  note (e.g. the real local endpoint). This file is read every session — every
  extra line is a recurring cost.
- **Overwrite the whole file on refresh — never append a second snapshot.**
  Two headers in one file means a refresh bug; the freshness check reads only
  the first.
- Cache **only slow-changing orientation**. Never cache volatile per-symbol
  metrics (hotspots/fan_in, call counts, layers, clusters) — they drift on
  every change and must be queried live at task time.
- Safe to commit; files are keyed by project name so synced `.github/agents/`
  directories coexist. Staleness protection is the signature check, not file
  presence.

## Refresh brief (dispatched to free-scout-flash, fallback cheap-generalist-kimi, when missing/stale)

> Call `get_architecture(project="<name>",
> aspects=["languages","packages","routes","entry_points"])` and
> `index_status(project="<name>")`. **Overwrite**
> `.github/agents/arch-cache/<name>.md` — single YAML header (`project`,
> `root_path`, `generated` = now, `graph_signature` from index_status, `git`),
> then orientation bullets only: stack + file counts, package layout, stable
> hand-verified notes carried over from the previous snapshot. **≤25 lines
> total. Never append a second snapshot; never include hotspots, boundaries,
> layers, or clusters.** Allowlist: that one file. Report `STATUS: pass` with
> the new node/edge counts. ≤120 words.

The orchestrator never writes these files itself (read-only); refresh via the
brief above, or manually with any agent that has MCP read + file write.
