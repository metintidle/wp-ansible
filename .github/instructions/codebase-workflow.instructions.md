---
applyTo: '**'
---

# Codebase discovery routing — graph for unknowns, files for knowns

The codebase index is a **discovery tool for unknown targets**, not a mandatory
preamble. Calling it when you already know the target burns rate limit and
context and returns nothing you did not have. Most tasks name their target and
must skip it entirely.

## Step 0 — classify the target before any tool call

**Known target** — the brief, the user prompt, or an `ANCHORS:` block names a
file, symbol, method, or line range → **read that file directly. Zero graph
calls.** A user prompt containing `#sym:` / `file.ts:110` / a function name is
a known target. This is the common case.

**Unknown target** — "which files own feature X", "who calls Y", "where is Z
defined", exhaustive enumeration for a batch → use the graph, narrowest query
first.

## Rules for unknown targets

1. **`PROJECT:` in the brief → never call `list_projects`.** Use the given
   identifier verbatim.
2. **`get_architecture` is orientation-only.** It is legal *only* inside an
   arch-cache refresh brief. `aspects: ["all"]` is banned outright — it is the
   single fattest call in the pool and answers no task-level question.
3. **Escalate in this order, stop at the first tool that answers:**
   `search_graph` (structured params, always with `file_pattern` + `limit` ≤5)
   → `get_code_snippet` → ripgrep `search` scoped to a glob → `read`.
4. **Two misses = the index does not have it.** Reformulating the same question
   a third time (new pattern, new label, new file_pattern) is a loop. Drop to
   ripgrep immediately.
5. **Hard budget: 6 discovery tool calls per task.** Hitting 6 means the
   question is wrong-shaped, not that you need a 7th. Stop and report what you
   have plus an explicit gap. A worker with an orchestrator above it hands back
   (`STATUS: needs-input`) instead of guessing.
6. **Never re-discover what the brief already contains.** Re-deriving anchors
   that were handed to you is a reportable routing miss.

## Index-vs-disk mismatch

The index may have been built from a different checkout or path than the
working tree (e.g. a Windows `D:\repo` index against a WSL `/home/x/repo`
tree). If a graph hit's line numbers or content do not match the file on disk,
**the graph is not authoritative for this task** — stop querying it, use
ripgrep + read, and say so in your report so the user can re-index.

## Why

Reading a named 120-line file is one call. Orienting a graph to rediscover that
same file is fifteen. The index earns its cost only when you genuinely do not
know where to look.
