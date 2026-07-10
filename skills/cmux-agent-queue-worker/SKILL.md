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

End the task by printing one report in the current conversation, replacing the example ID with the exact assigned ID:

```text
완료 보고 [T-YYYYMMDD-NNNN]: <summary>. 변경/생성: <paths or none>. 검증: <evidence>. 미실행: <reason>. 주의: <follow-up>.
```

Do not look up planner refs. Do not use `cmux send` for ordinary completion. Agent Queue detects this current-pane report, completes the matching task, and forwards the evidence to the planner.

If blocked, keep the same task ID and print the blocker, evidence gathered, and the decision or input required. Do not broaden scope to work around a safety or ownership boundary.

