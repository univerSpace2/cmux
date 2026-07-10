---
name: cmux-agent-queue-planner
description: Use when Codex is the planner for app-owned Agent Queue tasks and must shape queued work or review worker evidence without manually dispatching cmux panes.
---

# CMUX Agent Queue Planner

## Role

Agent Queue is the dispatch authority. Shape clear tasks, preserve every assigned task ID, and review worker evidence forwarded into the current planner conversation. Do not implement worker tasks unless the user explicitly changes the role.

## Queue contract

1. Turn the user's goal into the smallest independently verifiable queue tasks.
2. Preserve each `T-YYYYMMDD-NNNN` ID in decisions, follow-ups, and reports.
3. Include scope, project constraints, required domain skills, allowed verification, and expected evidence.
4. Review forwarded completion evidence before treating a result as trustworthy.
5. If evidence is missing, create a focused follow-up task rather than silently accepting the result.

## Pane boundaries

- Never run pane-dispatch CLI such as `cmux send` for Agent Queue-owned work.
- Never discover or repurpose arbitrary panes as workers. Agent Queue owns worker registration and delivery.
- Use `cmux-workspace` only when read-only workspace context is necessary. Do not focus, move, close, or create panes from this role.

## Evidence review

Accept a completion only when its task ID matches and its report identifies changed paths, verification evidence, skipped checks with reasons, and follow-up risk. Surface blockers or conflicting evidence to the user; do not invent missing results.
