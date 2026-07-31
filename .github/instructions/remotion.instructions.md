---
applyTo: 'remotion/**/*.tsx,remotion/**/*.ts'
---

## Remotion scene/component workflow

Apply this workflow to any task that adds or edits a scene, shared component,
or animation inside `remotion/src/` — composition timing, layout, motion, or
Studio interactivity. It does not apply to `landing/` (plain-JS marketing
page) or Python frame-extraction tooling in `scripts/`. For recreating motion
from a reference clip's extracted frames, use the dedicated
`mid-frame-motion-recreator` workflow instead — it already handles skill
loading, per-frame measurement, and self-check; do not duplicate that here.

1. Use Codebase Memory MCP to find existing scene/component conventions
   (`remotion/src/scenes/*.tsx`, `remotion/src/components/`) before writing
   new markup — match the shape of neighboring scenes rather than inventing a
   new pattern.
2. Load `remotion/.agents/skills/remotion-best-practices/SKILL.md` and follow
   it into the sub-skill that matches the task: `remotion-markup/SKILL.md`
   for scene/component markup (the common case), `remotion-render/SKILL.md`
   for render/CLI questions, `remotion-docs/SKILL.md` for API lookups,
   `remotion-captions/SKILL.md` only if touching captions, and
   `remotion-interactivity/SKILL.md` when improving Studio editability. Skip
   `remotion-create`/`remotion-saas` — this is an existing local-render video
   project, not a new app or a Player/Lambda SaaS deployment.
3. Animate every value with `useCurrentFrame()` + `interpolate()` (prefer it
   over `spring()` unless a spring specifically fits the motion); use
   `Easing.bezier()` for custom or overshooting timing. Never use CSS
   transitions/animations, `Math.random`, or wall-clock/`Date`-based timing.
4. Keep `interpolate()` calls inline in the `style` prop rather than hoisted
   to a variable, and prefer the `scale`/`translate`/`rotate` CSS properties
   over a `transform` string — both keep values scrubbable/editable in
   Remotion Studio. Wrap studio-editable elements in `Interactive.*` (e.g.
   `<Interactive.Div name="...">`) with a descriptive `name`.
5. Preserve `remotion/src/config.ts` (`FPS`, `COMP_W`, `COMP_H`) as the single
   source of truth — don't hardcode dimensions or frame rate in a scene.
6. New or reordered scenes are registered only in
   `remotion/src/scenes/manifest.ts` (`SCENES` array, each with `id`,
   `Component`, `durationInFrames`); `Root.tsx` derives both the `Main`
   `Series` and the per-scene debug `Composition` from that one list — do not
   duplicate ordering/duration elsewhere.
7. Run the targeted validation named in the brief (e.g. `npx remotion render`
   or a Studio preview per `remotion-render/SKILL.md`). If you cannot render
   or screenshot the result, do not claim visual QA passed — report that gap.
8. Report files changed, which existing scene/component conventions were
   followed, validation results, and any motion/timing assumptions made.
