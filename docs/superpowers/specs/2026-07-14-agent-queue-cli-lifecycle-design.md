# Agent Queue CLI Ingest and Agent Lifecycle Design

**Date:** 2026-07-14  
**Status:** Approved in design review  
**Scope:** macOS Agent Queue planner ingest, worker reporting, scheduling, and agent lifecycle

## Summary

Replace terminal-output parsing with an app-owned queue controlled through cmux's existing Unix socket JSON-RPC interface. The Planner submits an atomic task batch through the CLI, and Workers report task outcomes through the CLI. The queue starts scheduling immediately and never requires an explicit Start action. Dispatch concurrency is limited to Workers that are initialized, live, and idle.

Add event-driven agent lifecycle management. A startup handshake proves that an agent initialized, surface lifecycle events detect closed panes, a process supervisor reports a normally exited Codex process, and a low-frequency topology reconciliation covers missed surface events. Automatic and manual removal use one coordinator mutation path. Removing an agent never closes its pane.

## Goals

- Eliminate Planner plan extraction from terminal text.
- Eliminate Worker report extraction from terminal text.
- Preserve quotes, backslashes, newlines, and Unicode exactly across Planner and Worker payloads.
- Start scheduling immediately after a valid task batch is persisted.
- Dispatch no more tasks than the number of ready, live, idle Workers.
- Detect initialization failure, pane closure, surface loss, and supervised Codex exit.
- Provide automatic and manual agent removal without closing panes.
- Prevent duplicate execution when an active Worker disappears.
- Keep UI, CLI, lifecycle events, restore, and timeout handling on one mutation path.
- Preserve focus during every socket and background queue operation.

## Non-goals

- No localhost HTTP server.
- No automatic Planner or Worker pane recreation.
- No automatic reassignment of a task whose active Worker disappeared.
- No compatibility fallback that parses terminal output.
- No distributed or cross-machine queue.
- No planner approval gate after a Worker reports completion.

## Current Problems

The current flow sends a goal from the sidebar to the Planner, polls recent terminal text, parses a JSON plan, dispatches tasks, then polls Worker text for completion markers. This couples queue correctness to terminal rendering and escaping. It also leaves stale readiness and worker assignment state when an agent never initializes or its pane disappears.

The redesign removes the sidebar goal submission and both terminal response detectors. Terminal input remains only as the mechanism by which the app gives a task prompt to an interactive Worker; terminal output is never a queue protocol.

## Architecture

```text
User <-> Planner pane
             |
             | cmux agent-queue enqueue --stdin
             v
      Unix socket JSON-RPC
             |
             v
   AgentQueueCoordinator <------ UI / lifecycle / timeout / restore
             |
             +--> durable AgentQueueState
             |
             +--> AgentQueueCore scheduler
                       |
                       | prompt dispatch, no focus change
                       v
                  Worker panes
                       |
                       | cmux agent-queue report ... --stdin
                       +-------------------------------> coordinator
```

### `AgentQueueCoordinator`

The coordinator is the only queue mutation boundary. It serializes commands from the sidebar, JSON-RPC bridge, topology reconciler, readiness deadlines, task timeouts, and state restoration. Each command produces a complete next state through pure queue transitions, persists that state atomically, and only then publishes it to the UI or begins dispatch side effects.

UI actions and CLI methods must not duplicate reducer logic. Automatic and manual removal both call the same `removeAgent` coordinator operation with a recorded cause.

### `ControlAgentQueueContext`

`CmuxControlSocket` must not depend on app-owned Agent Queue types. A protocol bridge carries validated request values from `ControlCommandCoordinator` into the app composition root. JSON decoding and validation run off the main thread. Only the smallest UI state publication and pane operation cross to `@MainActor`.

Socket calls must not select a workspace, activate a window, focus a pane, or change the current surface.

### `AgentQueueTopologyReconciler`

The reconciler consumes `surface.closed` events and compares registered bindings with the workspace's actual terminal surfaces. It also runs:

- after preparation,
- after state restoration,
- when the app becomes active, and
- on a 10-second safety interval.

Reconciliation checks topology only. It never reads terminal text.

### Agent bindings

Every preparation attempt creates a unique `binding_id` for an agent ID and surface ID. Bootstrap, ready, offline, report, timeout, and close events carry or resolve that binding generation. A stale command from a removed or replaced agent cannot mutate the new binding.

The Planner is a mandatory role rather than a deletable queue member. Removing it clears its surface binding and marks it `notReady`. Workers are removed from execution capacity.

### State additions

The durable model adds these explicit records:

- `schemaVersion` and monotonically increasing queue `revision`;
- `AgentQueueAgentBinding`: binding ID, agent ID, role, workspace ID, surface ID, readiness, and lifecycle timestamps;
- `AgentQueueSubmission`: submission ID, canonical payload digest, generated task IDs, and creation time; and
- `AgentQueueTaskReport`: report ID, requested status, exact report body, reporting binding ID, attempt number, and report time.

Submission records make enqueue idempotency survive app restart. Task reports make report idempotency and audit independent of transient event text.

## CLI and JSON-RPC Contract

The existing Unix socket remains the sole transport and source of truth. The CLI is a thin wrapper.

### RPC methods

```text
agent_queue.agent.ready
agent_queue.agent.offline
agent_queue.agent.list
agent_queue.agent.remove
agent_queue.agent.reconcile

agent_queue.task.enqueue
agent_queue.task.report
agent_queue.task.list

agent_queue.pause
agent_queue.resume
```

There is no `agent_queue.start` method.

### Workspace routing

Planner and Worker panes use their injected `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, and `CMUX_SOCKET_PATH`. The CLI derives routing from this context. Requests fail rather than falling back to a focused workspace when required context is absent or inconsistent.

### Ready handshake

The first required action in each Planner or Worker bootstrap instruction is:

```bash
cmux agent-queue agent ready \
  --agent worker-1 \
  --role worker \
  --binding BINDING_ID
```

The coordinator accepts the handshake only when the agent ID, role, binding generation, workspace, and calling surface match a pending preparation record. The existing 30-second preparation timeout is the handshake deadline. A missing handshake is a preparation failure and removes that registration.

Codex processes already observed by the app's agent transcript service are followed through its non-terminal-text lifecycle state. An observed `ended` state produces the same offline coordinator command. Codex launched by Agent Queue also uses a small supervision wrapper; on normal process exit, the wrapper invokes `agent offline` with the same binding ID. Pane destruction may prevent that final command, so `surface.closed` remains authoritative for surface loss.

### Atomic Planner enqueue

```bash
cmux agent-queue enqueue --stdin
```

stdin contains one UTF-8 JSON object:

```json
{
  "submission_id": "planner-generated-stable-id",
  "tasks": [
    {
      "title": "Implement parser",
      "body": "Task instructions, including \\ paths and multiline text.",
      "execution_mode": "parallel",
      "timeout_seconds": 1800,
      "retry_limit": 1
    }
  ]
}
```

Contract:

- Only the current ready Planner binding on its registered surface may enqueue.
- `submission_id` is required and unique within a workspace queue.
- `tasks` must contain at least one task.
- `title` and `body` must be non-empty after validation.
- `execution_mode` is `parallel` or `sequential`.
- `timeout_seconds` must be positive.
- `retry_limit` must be zero or greater.
- The app generates queue task IDs.
- The complete batch is rejected if any task is invalid.
- A repeated `submission_id` returns the original result and creates no tasks.
- A conflicting payload using an existing `submission_id` returns a conflict error.

The standard JSON decoder consumes stdin bytes directly. Terminal screen capture, line wrapping, shell echo, and response-marker unescaping are not involved.

### Worker report

```bash
cmux agent-queue report \
  --task TASK_ID \
  --report REPORT_ID \
  --status completed \
  --binding BINDING_ID \
  --stdin
```

stdin is an optional plain UTF-8 result or diagnostic body. `REPORT_ID` is a Worker-generated stable ID for this report attempt. Valid statuses are `completed`, `failed`, and `blocked`.

The coordinator verifies that the calling workspace, surface, binding generation, and assigned task agree. Repeating a `REPORT_ID` with the same payload returns its original result, including for a retryable failed report. Reusing a report ID with different content, or sending a conflicting report for an already terminal task, returns a conflict error.

CLI success responses are structured JSON on stdout. Validation, authorization, conflict, persistence, and transport failures use nonzero exit status and a structured error on stderr.

## Scheduling Semantics

### Immediate operation

There is no Start or batch-start state. A newly prepared queue is `running` and idle. Enqueue persists the batch and immediately invokes scheduling. When the queue drains it remains `running` and idle, so the next enqueue dispatches immediately.

Manual or safety pause is sticky. Enqueue while paused persists tasks but does not resume the queue. Recovery or re-preparation also does not silently clear a safety pause; the user must invoke Resume.

### Capacity

Dispatch capacity equals the count of Workers that are all of:

- initialized through the current binding's ready handshake,
- backed by an existing terminal surface,
- not offline or removed, and
- idle.

Queued tasks beyond this capacity remain queued.

### Ordering

The scheduler preserves FIFO order and existing execution-mode barriers:

- Parallel tasks fill available Worker capacity in queue order.
- A sequential task waits for all earlier active work to finish, runs alone, and blocks later tasks until it finishes.
- A later parallel task cannot bypass an earlier sequential barrier.

### Dispatch and report transitions

1. `queued` task plus eligible Worker becomes `dispatching`/`assigned`.
2. The pane adapter submits the prompt and Enter without focusing the pane.
3. Successful submission becomes task `dispatched` and Worker `running`.
4. `completed` report makes the task terminal, releases the Worker to `idle`, persists the report body, and immediately schedules the next task.
5. `failed` report keeps the same live Worker assigned and sends that Worker a recovery prompt while `recoveryAttemptCount < retryLimit`. Each recovery increments the count. When the limit is exhausted, the task becomes `failed`, the Worker is released, and the queue pauses. A failed task is never reassigned automatically to another Worker.
6. `blocked` report makes the task `blocked` and pauses the queue.
7. Dispatch failure makes the task `blocked`, releases/removes the invalid binding as applicable, and pauses the queue.
8. A dispatched task timeout makes the task `blocked`, removes that Worker binding from capacity, and pauses the queue.

The legacy `awaitingReport` screen-detection phase is no longer produced. Legacy enum cases may remain only as decode compatibility until persisted-state migration is complete.

## Lifecycle and Removal Policy

| Trigger | Agent registration | Active task | Queue | Pane |
|---|---|---|---|---|
| Worker ready timeout | Remove | None | Continue with remaining Workers | Keep |
| Idle Worker surface loss or process exit | Remove | None | Continue with remaining Workers | Already lost or keep |
| Active Worker surface loss or process exit | Remove | Mark `blocked` | Pause | Already lost or keep |
| Active Worker manual removal | Remove | Mark `blocked` | Pause | Keep |
| Planner ready timeout, loss, or exit | Clear binding; mark `notReady` | Preserve tasks | Pause | Already lost or keep |
| Planner manual removal | Clear binding; mark `notReady` | Preserve tasks | Pause | Keep |

Manual removal only unregisters the agent. It never closes the pane or terminates Codex. Stale `ready`, `offline`, and `report` calls for the removed binding are rejected or treated as harmless stale notifications.

Active Worker loss never requeues its task automatically. The task may already have changed external state, so reassignment would risk duplicate side effects. The user resolves or retries the blocked task explicitly after inspecting it.

No loss path automatically creates a pane or starts Codex.

## Persistence and Atomicity

The app-owned queue state remains persisted per workspace under the existing Agent Queue persistence location. Mutations follow this order:

1. Decode and validate the command.
2. Serialize against the current queue revision.
3. Compute the complete next state with pure transitions.
4. Write the next state using a temporary file and atomic replacement.
5. Publish the committed state.
6. Run dispatch side effects.
7. Persist success or failure transitions caused by those side effects.

An enqueue response is successful once the batch is durable; it does not wait for every prompt dispatch. Persistence failure publishes no partial state and triggers no dispatch. If a post-commit dispatch side effect fails, the coordinator records the explicit blocked/pause transition rather than rolling the durable enqueue back.

## Legacy Migration

The persisted schema gains an explicit version and binding-generation data.

On first restore after upgrade:

- `queued`, `completed`, `failed`, `blocked`, and `cancelled` tasks are preserved.
- Legacy in-flight states (`dispatching`, `dispatched`, `awaiting_report`, and `retrying`) become `blocked` with a migration reason, preventing duplicate execution.
- Existing Planner and Worker readiness records become `notReady`; the user must re-prepare agents so they receive the CLI contract.
- The queue is paused when any task was migrated from an in-flight state or when the Planner is not ready.
- Legacy planning request, response fingerprint, and screen-monitor state are discarded.

Migration is idempotent and persisted immediately. It never sends a prompt or closes a pane.

## Sidebar Changes

Remove:

- Goal input,
- Planner response waiting/error UI tied to terminal parsing, and
- Start button.

Keep or add:

- Planner readiness and binding status,
- Worker readiness, surface, and assigned-task status,
- queued/running/blocked/completed task list,
- Pause/Resume,
- per-agent Remove Registration,
- Re-prepare/Reassign actions, and
- actionable validation, migration, and lifecycle errors.

All rows below SwiftUI collection boundaries receive immutable snapshots and action closures, not observable queue/controller references.

## Removed Runtime Paths

- Planner terminal response polling.
- Worker terminal report polling.
- Recent-line extraction used for queue protocols.
- `AgentQueuePlanDetector` runtime usage.
- `AgentQueueReportDetector` runtime usage.
- Planner malformed-JSON correction requests.

Detector files and tests should be deleted when no remaining production reference exists. Pane readiness must use the explicit handshake rather than reintroducing terminal-text inspection.

## Error Handling

- Invalid enqueue input: reject whole batch; no state change.
- Missing workspace/surface context: reject; never use focused UI as fallback.
- Unknown or stale binding: reject without affecting current registration.
- Wrong Worker reporting a task: reject; task remains active.
- Duplicate identical submission/report ID: return prior result.
- Conflicting idempotency key or terminal report: return conflict.
- Persistence failure: return failure; do not publish or dispatch uncommitted state.
- Planner loss: pause and require explicit re-preparation plus Resume.
- Active Worker loss or timeout: block, pause, and require explicit user recovery.
- Idle Worker loss: reduce capacity and continue safely.

Every error is recorded in Agent Queue events with enough workspace, agent, binding, task, and cause data for diagnosis, excluding task body duplication or secrets.

## Verification Strategy

### Pure model and coordinator tests

- Valid atomic batch enqueue.
- One invalid task rejects the full batch.
- Identical `submission_id` is idempotent.
- Conflicting `submission_id` is rejected.
- FIFO dispatch is capped by ready/live/idle Worker count.
- Sequential barriers remain exclusive.
- Completion immediately schedules the next eligible task.
- Failure retry limit remains correct.
- Duplicate failed `REPORT_ID` does not consume another retry.
- Blocked report pauses the queue.
- Enqueue while paused does not resume.
- Persistence failure publishes no mutation.

### Payload regression tests

Round-trip Planner task titles/bodies and Worker report bodies containing:

- double and single quotes,
- backslashes and Windows-style paths,
- literal escape-looking sequences,
- tabs and newlines,
- emoji and non-Latin Unicode, and
- long multiline Markdown/code blocks.

Assertions compare exact decoded strings, not normalized display output.

### Lifecycle tests

- Ready accepted only for matching pending binding and surface.
- Ready timeout removes an uninitialized Worker.
- Stale ready/offline cannot remove a replacement binding.
- Idle Worker close reduces capacity without pausing.
- Active Worker close blocks its task and pauses.
- Active Worker manual removal uses the same state transition and keeps the pane.
- Planner close or manual removal clears its binding and pauses.
- Reconciliation repairs a missed close event.
- No lifecycle path automatically creates or closes a pane.

### Socket and CLI tests

- CLI argument/stdin mapping to each JSON-RPC method.
- Structured success and error rendering plus exit codes.
- Workspace routing from injected environment.
- Wrong or missing context rejection.
- Socket calls do not activate a window or change focused workspace/surface.
- Parsing and validation remain off main; app mutation is serialized.

### Persistence and migration tests

- New state round-trip including binding IDs and submission IDs.
- Legacy queued and terminal tasks are preserved.
- Every legacy in-flight state migrates to blocked.
- Legacy readiness is invalidated.
- Migration is idempotent and causes no dispatch.

### UI, localization, and build checks

- Goal input and Start action are absent.
- Pause/Resume and registration removal call coordinator actions.
- List rows obey immutable snapshot boundaries.
- Every changed user-facing string has English and Japanese catalog entries.
- Changed localization catalogs parse and contain matching locale coverage.
- Any new `cmuxTests` source is wired into `cmux.xcodeproj/project.pbxproj`.
- Focused tests run with nonzero executed-test counts.
- `scripts/reload.sh --tag agent-queue-planner-ingest` completes successfully.

## Acceptance Criteria

1. Planner can submit a multi-task plan with exact special-character preservation using `cmux agent-queue enqueue --stdin`.
2. A valid enqueue becomes durable and automatically dispatches up to current Worker capacity without Start.
3. Worker completion through `cmux agent-queue report` releases the Worker and schedules the next task without terminal polling.
4. No production Agent Queue path reads terminal output to discover plans or reports.
5. An agent that does not complete the ready handshake is not counted as available.
6. Closing an idle Worker removes it and lets other Workers continue.
7. Closing or manually unregistering an active Worker blocks its task and pauses the queue without reassigning it.
8. Planner loss clears readiness and pauses without recreating a pane.
9. Manual removal leaves the pane and agent process untouched.
10. UI, CLI, lifecycle, timeout, restore, and reconciliation paths share coordinator mutations and preserve focus.
