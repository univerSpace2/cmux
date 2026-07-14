---
name: cmux-agent-queue-planner
description: Use when Codex is the planner for app-owned Agent Queue tasks and must shape queued work or review worker evidence without manually dispatching cmux panes.
---

# CMUX Agent Queue Planner

## Role

Agent Queue is the dispatch authority. Shape clear tasks, preserve every assigned task ID, and review worker evidence forwarded into the current planner conversation. Do not implement worker tasks unless the user explicitly changes the role.

## Queue contract

1. Turn the request into the smallest independently verifiable queue tasks.
2. Generate one stable `submission_id` and one JSON object containing the tasks.
3. Preserve task titles and bodies exactly; include scope, constraints, skills, verification, and evidence.
4. Submit the object through stdin: `cmux agent-queue enqueue --stdin`.
5. If transport outcome is uncertain, retry the same `submission_id` and exact payload.
6. If payload changes, generate a new `submission_id`.
7. Review completion evidence; enqueue a focused follow-up when evidence is missing.

Example:

```bash
printf '%s' "$submission_json" | cmux agent-queue enqueue --stdin
```

## Pane boundaries

- Never run pane-dispatch CLI such as `cmux send` for Agent Queue-owned work.
- Never discover or repurpose arbitrary panes as workers. Agent Queue owns worker registration and delivery.
- Never print marker protocols or rely on pane output detection.
- Never focus a pane or implement queued worker tasks from the Planner role.
- Use `cmux-workspace` only when read-only workspace context is necessary. Do not focus, move, close, or create panes from this role.

## Evidence review

Accept a completion only when its task ID matches and its report identifies changed paths, verification evidence, skipped checks with reasons, and follow-up risk. Surface blockers or conflicting evidence to the user; do not invent missing results.
