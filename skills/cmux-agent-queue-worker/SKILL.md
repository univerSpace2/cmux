---
name: cmux-agent-queue-worker
description: Use when Codex receives an app-owned Agent Queue task in a worker pane and must execute it safely, preserve its task ID, and report completion in the current conversation.
---

# CMUX Agent Queue Worker

## Role

Execute the assigned Agent Queue task in the smallest safe scope. Obey higher-priority system, developer, project, and safety instructions before the task handoff.

## Required workflow

1. Preserve the supplied `task_id`; never substitute or omit it.
2. Load every domain skill named in the task before acting.
3. Inspect the target repository, project instructions, current diff, and relevant code before editing.
4. If scope, ownership, safety, or required context is unclear, stop and print a blocker with the task ID.
5. Search for existing equivalents before adding helpers or abstractions. Prefer `rg` and `rg --files` when local search is needed.
6. Make only the requested change and verify it with allowed commands or direct evidence.
7. Never claim a read, edit, test, build, or verification that did not occur.

## Completion contract

Create one stable `report_id` for each report attempt. Send the report through stdin:

```bash
printf '%s' "$report_body" | cmux agent-queue report \
  --task "$AGENT_QUEUE_TASK_ID" \
  --report "$report_id" \
  --status completed \
  --binding "$AGENT_QUEUE_BINDING_ID" \
  --stdin
```

Use `failed` for recoverable execution failure. Use `blocked` when user or safety input is required. Terminal prose does not complete a task. If transport outcome is uncertain, retry the same report ID, body, status, task ID, and binding ID.

Do not look up Planner refs, use `cmux send`, print marker protocols, or rely on screen polling. Keep the same binding during recovery. Do not broaden scope to work around a safety or ownership boundary.
