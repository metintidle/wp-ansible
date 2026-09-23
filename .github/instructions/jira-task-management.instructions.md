---
description: "Use when creating, updating, transitioning, or closing Jira issues for WordPress fleet work. Enforces WEPC project defaults, management-facing descriptions, and automatic task lifecycle."
applyTo: "**"
---

# Jira task management — WordPress / WEPC

Use the Atlassian Rovo MCP integration for every Jira operation in this workspace.

## Default Jira destination

Unless the user explicitly overrides a value:

- Cloud ID: `d44de458-5093-4475-aa45-852744950502`
- Project: **WordPress** (`WEPC`, project ID `10005`)
- Board: **WEPC board** (ID `6`)
- Issue type: **Task** (`10024`); use Epic or Subtask only when requested.
- Assignee: `712020:511898f6-d703-4a94-9c60-86d6ac340b7f` (Mahdi)
- Dates use the `Australia/Sydney` calendar in `YYYY-MM-DD` format.

Do not ask for project, board, or assignee when these defaults apply. Only call `getAccessibleAtlassianResources` if the configured Cloud ID fails.

## Creating issues

For concrete, non-trivial work in this repository—host changes, fixes, installations, configuration changes, cleanups, deployments, incident response, or multi-step implementation—create a WEPC task before starting work.

Do **not** auto-create an issue for questions, read-only status checks or lookups, conversation, or trivial no-impact checks.

When creating a task:

1. Always include a description; never create a summary-only issue.
2. Set Start date (`customfield_10015`) to the created date in Sydney. If the create response exposes a different created date, update the Start date to match it.
3. Leave the due date empty unless the user provides one.
4. Move the task to **In Progress** (transition ID `21`) when created; do not leave it in To Do unless requested.
5. State the issue key before beginning the work.

Use this description format, written for non-technical management. Keep it professional, direct, outcome-focused, and free of code, paths, framework names, and implementation jargon:

```markdown
**Business Goal**
<One or two sentences explaining the value and purpose.>

**Summary of Work**
- <Plain-English outcome>
- <Plain-English outcome>
- <Optional third outcome>
```

## Completing work

After successful work, transition the issue to **Done** using transition ID `31` and set its due date to today in Sydney. Do not overwrite an existing due date unless the user requests it.

If the transition does not accept the due date, set it immediately with an issue edit. If the work fails or stalls, leave the issue In Progress and identify it as blocked in the response.

State the closed issue key in the final response after successful completion.

## User overrides

Honor any user-specified assignee, project, start date, due date, issue type, or requested status. Do not re-look up the default assignee unless the stored account ID fails.
