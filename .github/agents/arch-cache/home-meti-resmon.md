---
project: home-meti-resmon
root_path: /home/meti/resmon
generated: 2026-07-22T00:00:00Z
graph_signature:
  nodes: 21717
  edges: 32302
git:
  is_git: true
  branch: master
---

- stack: TypeScript 734 / HTML 72 / SQL 24 / Rust 11 / Bash 6 / SCSS 6 / CSS 6
  / JavaScript 4 (~866 files). Nx-style monorepo (apps/*).
- packages: `apps/server` (2328 nodes) — Nest backend. `apps/dashboard`
  (1102) — Angular admin/customer panel (case-overview, customer-panel,
  staff-attendance, ticket-chat). `apps/3cx-integration-config` (105) — 3CX
  phone integration. `apps/wp-agent` (40) — WordPress agent.
  `apps/wp-agent-rollout-ec2-user` (4), `apps/vault` (4), `apps/deploy-local`
  (3).
- volatile metrics (hotspots, fan-in, layers, clusters): query live at task
  time, never from this file.
