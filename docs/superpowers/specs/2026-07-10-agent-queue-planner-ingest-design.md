# Agent Queue Planner Ingest and Reliable Submission Design

## Goal

Make Agent Queue use the planner as the source of queued work and make every
programmatic prompt submission behave like an actual composer submission.

The change must provide three user-visible guarantees:

1. Preparing a planner or worker sends only a role-start signal. It must not
   send a role-end signal that an agent can misinterpret as termination.
2. Entering a goal sends it to the planner. The planner's structured task list
   is detected and added to the queue automatically.
3. Starting work pastes the worker instruction and submits it with Return. It
   must not leave the worker at a `[Pasted Content ...]` draft.

Existing global skills remain untouched. Agent Queue continues to use its
app-owned role skills and per-agent skill/profile configuration.

## Chosen Approach

Use a small terminal protocol between the app and the planner. The planner
prints a marker-delimited JSON payload, and the app's existing terminal polling
loop parses and imports it.

This is preferred to giving the planner an app-control command because it keeps
the agent unprivileged and makes validation, deduplication, persistence, and
tests app-owned. It is preferred to app-side text splitting because the planner
must perform the decomposition.

## Role Start Prompt

`AgentQueueSkillPromptBuilder` emits role and additional skill invocations,
followed by one explicit start marker:

```text
$cmux-agent-queue-worker $some-additional-skill

[AGENT_QUEUE_ROLE_START]
<per-agent role prompt>
```

There is no closing marker. Planner and worker preparation, task dispatch,
recovery, and forwarded reports all use the same prompt builder, so no path can
reintroduce the old `[/AGENT_QUEUE_ROLE]` signal.

## Planner Request Protocol

When the user submits a non-empty goal, the controller creates a UUID request
ID and sends this instruction to the configured planner pane:

```text
사용자 목표를 실행 가능한 작업으로 분해하세요.

[AGENT_QUEUE_PLAN_REQUEST]
request_id: <UUID>
goal:
<user goal>
[/AGENT_QUEUE_PLAN_REQUEST]

설명이나 Markdown 코드 펜스 없이 다음 형식만 출력하세요.
[AGENT_QUEUE_TASKS]
{"request_id":"<same UUID>","tasks":[{"title":"...","body":"..."}]}
[/AGENT_QUEUE_TASKS]
```

The response schema is:

- `request_id`: the exact pending request UUID
- `tasks`: one or more task objects
- `title`: non-empty display title
- `body`: non-empty worker instruction

The controller accepts only a response whose request ID matches the currently
pending request. It trims titles and bodies, rejects an empty task list or empty
fields, and imports all valid tasks in one state update. Imported tasks start as
sequential, queued work with the existing retry and timeout defaults.

Only one planning request may be pending at a time. This makes deduplication
explicit: after a response is imported, the pending request is cleared, so the
same terminal output cannot be imported again. A new request receives a new
UUID.

## Planning State and Persistence

`AgentQueueState` gains an optional planning request containing:

- request ID
- original goal
- phase (`submitting`, `waiting_for_planner`, or `failed`)
- creation time
- optional error message

The field is optional so older persisted queue JSON decodes without migration.
The pending request is persisted before/after submission state transitions and
survives app restart. Restored pending work resumes planner-output polling but
does not automatically resend the goal, avoiding duplicate planner turns.

The monitoring loop runs while either executable tasks are active or a planning
request is waiting. Planner response detection happens only on the planner
surface. Worker report detection remains unchanged.

## UI Behavior

The existing task input becomes planner goal input.

- Primary action: **Send to Planner**
- Disabled when input is empty, planner preparation is not ready, or another
  planning request is pending
- The editor clears only after the prompt was accepted for submission
- Waiting state shows that the planner is decomposing the goal
- Failure state shows the submission/parsing error and keeps the original goal
  available for retry
- After successful import, queued task rows appear normally and the Start button
  becomes available under the existing readiness rules

No direct `AgentTaskSplitter` path is used by this UI.

## Reliable Prompt Submission

Replace the adapter's split `sendText`/`sendEnter` contract with one
`submitText` operation. The app adapter routes it through the same TextBox
submission machinery used by the macOS composer:

```text
pasteText(payload) -> namedKey(return) -> completion
```

This path uses paste-style terminal input rather than raw socket input and
serializes overlapping submissions per surface. The async adapter call completes
only after the event runner has accepted both the paste and Return events. A
rejected paste or key becomes a submission error.

The unified operation is used for:

- initial planner/worker role preparation
- planner goal requests
- worker task dispatch from Start
- worker recovery prompts
- forwarding worker reports to the planner

This removes the race-prone public split between pasting and pressing Enter and
makes tests assert one complete submission rather than two unrelated fake calls.

Launching the `codex` process itself remains raw shell input plus Return because
it is a shell command, not an in-agent composed prompt.

## Error Handling

- Planner submission rejection: planning phase becomes failed and the goal is
  retained for retry.
- Marker present but JSON malformed: planning phase becomes failed with a
  concise parse error; no partial tasks are added.
- Valid JSON with wrong request ID: ignored as stale output.
- Empty or invalid tasks: request fails atomically; no tasks are added.
- Worker dispatch submission rejection: existing dispatch failure transition is
  retained, now with a single submission stage.
- Recovery/report forwarding submission rejection: remains best-effort where it
  is today, but uses the reliable unified submission path.

## Tests

Add or update tests to prove:

1. Role prompts contain `[AGENT_QUEUE_ROLE_START]` and no role-end marker.
2. Planner instructions contain the exact request ID, goal, and response schema.
3. The detector parses marker-delimited JSON, rejects malformed/empty payloads,
   and distinguishes stale request IDs.
4. Submitting a goal records a complete planner submission and enters waiting
   state; rejection enters failed state without deleting the goal.
5. Polling planner output imports tasks once and clears the pending request.
6. Monitoring remains active for a pending planning request with no tasks.
7. Start performs one complete worker submission and dispatch failure is
   recorded if that operation fails.
8. The app adapter's submission event sequence is paste then Return, with a
   regression test that fails under the old raw-input/split-enter implementation.
9. Legacy persisted state without planning data still decodes.
10. Existing Agent Queue controller, preparation, report, store, and core suites
    remain green.

## Out of Scope

- Modifying or replacing the user's existing global delegation/worker skills
- Allowing the planner to execute privileged cmux queue commands
- Multiple simultaneous planning requests
- Automatically starting the queue immediately after planner import
- Changing worker completion-report semantics
