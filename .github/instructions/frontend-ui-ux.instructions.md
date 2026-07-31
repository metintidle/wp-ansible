---
applyTo: '**/*.html,**/*.css,**/assets/**'
---

## Frontend UI/UX workflow

Apply this workflow only when a task creates or materially changes HTML, CSS,
client-side UI behavior, responsive layout, accessibility, or visual design.
Do not invoke it for copy-only, narrow logic-only, or non-UI changes.
Do not use it for Remotion frame-recreation tasks; follow the specialized
`mid-frame-motion-recreator` workflow for those instead.

1. Use Codebase Memory MCP to identify the existing frontend stack, component
   conventions, styling system, and relevant UI symbols before editing.
2. For a new screen, redesign, visual polish, or component-system change,
   read and follow the installed `ui-styling` skill. Also use `design-system`
   when the task introduces reusable tokens, component variants, or a shared
   visual language. Do not use either skill for a localized UI bug unless the
   brief explicitly asks for design work.
3. Preserve the project's existing framework, CSS methodology, component
   library, tokens, typography, and visual language. Never introduce Tailwind,
   shadcn/ui, a new font, or a new design system solely because a skill lists
   it as an option.
4. Keep the change scoped. Do not refactor unrelated UI or replace existing
   components without a concrete requirement.
5. Meet these implementation checks where applicable:
   - semantic HTML, labels, accessible names, and sensible heading order
   - keyboard operation, visible focus states, and no keyboard traps
   - sufficient text contrast and `prefers-reduced-motion` for new motion
   - responsive behavior at 375px, 768px, 1024px, and 1440px
   - loading, empty, error, disabled, and validation states for changed UI
6. Run the targeted validation named in the brief. If browser or screenshot
   tools are available, render the affected UI at the required breakpoints and
   inspect the screenshots. If they are not available, do not claim visual QA
   passed; report that validation gap.
7. Report files changed, the stack/conventions preserved, validation results,
   viewport coverage, and remaining visual or accessibility risks.
