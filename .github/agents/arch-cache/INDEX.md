# Project identity map — working directory → index project id

**Read this file, do not slugify the working directory.** The index server may
have been built from a different path than the working tree (Windows drive
path vs. WSL mount, container mount vs. host), so a cwd slug can never resolve
the identifier. Guessing costs a `list_projects` round-trip every session.

| Working directory | Index project id | Notes |
|---|---|---|
| `/home/meti/resmon` | `home-meti-resmon` | User-verified. Ignore any `D-resmon` entry `list_projects` may also return — it is a stale index of a different checkout. |

Cache file per project id: `<project-id>.md` (e.g. `home-meti-resmon.md`).

Working directory absent from this table → one `list_projects` (consume only
`name` + `root_path`), add the row, then proceed. Never call `list_projects`
again once a row exists. **A row here outranks a `list_projects` result** —
if the server returns an id that disagrees with this table, the table wins;
report the discrepancy, do not switch projects mid-task.

**Index-vs-disk check:** if a graph hit's line numbers or content do not match
the file on disk, the index is stale or built from another checkout. Abandon
the graph for that task, use `search`/`read`, and report it — see
`.github/instructions/codebase-workflow.instructions.md`.
