# Agent Queue Planner Ingest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route goal input through the planner, import its structured task response into Agent Queue, emit only a role-start signal, and submit every in-agent prompt with paste plus Return.

**Architecture:** Add a persisted optional planning request to the existing queue state and a focused parser for the planner's marker-delimited JSON response. Replace controller and preparation prompt paths with one async submission operation backed by the existing TextBox event runner, while retaining raw input only for launching the `codex` shell command.

**Tech Stack:** Swift 6, SwiftUI, Observation/Combine-compatible existing controller, Foundation `Codable`, TextBox terminal submission events, Swift Testing/XCTest in the existing Xcode test target.

## Global Constraints

- Do not modify `~/.codex/skills/cmux-pane-delegator/SKILL.md` or `~/.codex/skills/pane-agent-worker/SKILL.md`.
- Role prompts contain `[AGENT_QUEUE_ROLE_START]` and no role-end marker.
- Planner responses are marker-delimited JSON and only the current request ID may be imported.
- One planning request may be active at a time; imported tasks are added atomically and only once.
- In-agent prompts use paste-style input followed by Return; only the `codex` shell launch uses raw input plus Return.
- Write failing behavioral regression tests before production changes and commit the red tests separately from the fix.
- All changed user-facing strings must exist in every locale represented in `Resources/Localizable.xcstrings`.
- Build and launch only with the isolated tag `agent-queue`; never launch an untagged Debug app.
- Never stage or modify `.serena/`.

---

### Task 1: Specify Role Start and Planner Protocol

**Files:**
- Modify: `cmuxTests/AgentQueuePreparationTests.swift`
- Modify: `cmuxTests/AgentQueueInstructionBuilderTests.swift`

**Interfaces:**
- Consumes: existing `AgentQueueSkillPromptBuilder.prompt(role:profile:)` and `AgentQueueInstructionBuilder`.
- Produces: executable requirements for the role marker and `plannerRequest(goal:requestID:profile:)` prompt.

- [ ] **Step 1: Change the role-prompt expectations to start-only behavior**

Update the preparation assertions to expect values such as:

```swift
"$cmux-agent-queue-planner\n\n[AGENT_QUEUE_ROLE_START]\n"
"$cmux-agent-queue-worker\n\n[AGENT_QUEUE_ROLE_START]\n"
"$cmux-agent-queue-worker $api-integration\n\n" +
    "[AGENT_QUEUE_ROLE_START]\nOwn API integration."
```

Also assert that every submitted role prompt does not contain either
`[/AGENT_QUEUE_ROLE]` or `[AGENT_QUEUE_ROLE_END]`.

- [ ] **Step 2: Add a planner request prompt test**

Add a test using the fixed request ID
`11111111-2222-3333-4444-555555555555` and goal `Implement search.\nCover errors.`.
The expected prompt must include the planner role invocation, the exact goal,
the request ID in both the request and example response, and these markers:

```swift
XCTAssertTrue(text.contains("[AGENT_QUEUE_PLAN_REQUEST]"))
XCTAssertTrue(text.contains("request_id: 11111111-2222-3333-4444-555555555555"))
XCTAssertTrue(text.contains("Implement search.\nCover errors."))
XCTAssertTrue(text.contains("[AGENT_QUEUE_TASKS]"))
XCTAssertTrue(text.contains("\"request_id\":\"11111111-2222-3333-4444-555555555555\""))
```

- [ ] **Step 3: Run focused tests and verify RED**

Run with a tagged derived-data directory:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-agent-queue-tests \
  -only-testing:cmuxTests/AgentQueuePreparationTests \
  -only-testing:cmuxTests/AgentQueueInstructionBuilderTests test
```

Expected: FAIL because the old role end marker is still emitted and
`plannerRequest` does not exist.

- [ ] **Step 4: Commit the red protocol tests**

```bash
git add cmuxTests/AgentQueuePreparationTests.swift cmuxTests/AgentQueueInstructionBuilderTests.swift
git commit -m "test: specify planner queue protocol"
```

---

### Task 2: Implement Role Start and Planner Request Builder

**Files:**
- Modify: `Sources/AgentQueue/AgentQueueSkillSupport.swift`
- Modify: `Sources/AgentQueue/AgentQueueInstructionBuilder.swift`

**Interfaces:**
- Consumes: `AgentQueueAgentProfile`, `AgentQueueRoleSkill`.
- Produces: `AgentQueueInstructionBuilder.plannerRequest(goal:requestID:profile:) -> String` and start-only role prompts.

- [ ] **Step 1: Emit the role-start marker without a closing marker**

Implement `AgentQueueSkillPromptBuilder.prompt` with boundary-newline trimming so an empty role is stable:

```swift
let invocations = (["$\(role.rawValue)"] + profile.additionalSkills.map(\.invocation))
    .joined(separator: " ")
let rolePrompt = AgentQueueProfileFingerprint.normalizeLineEndings(profile.rolePrompt)
    .trimmingCharacters(in: .newlines)
return "\(invocations)\n\n[AGENT_QUEUE_ROLE_START]\n\(rolePrompt)"
```

- [ ] **Step 2: Add the planner request builder**

Add:

```swift
static func plannerRequest(
    goal: String,
    requestID: UUID,
    profile: AgentQueueAgentProfile
) -> String {
    let id = requestID.uuidString.lowercased()
    let instruction = """
    사용자 목표를 실행 가능한 작업으로 분해하세요.

    [AGENT_QUEUE_PLAN_REQUEST]
    request_id: \(id)
    goal:
    \(goal)
    [/AGENT_QUEUE_PLAN_REQUEST]

    설명이나 Markdown 코드 펜스 없이 다음 형식만 출력하세요.
    [AGENT_QUEUE_TASKS]
    {"request_id":"\(id)","tasks":[{"title":"작업 제목","body":"구체적인 작업 지시"}]}
    [/AGENT_QUEUE_TASKS]
    """
    return plannerInstruction(instruction, profile: profile)
}
```

- [ ] **Step 3: Run the focused tests and verify GREEN**

Run the Task 1 command. Expected: all selected tests PASS.

- [ ] **Step 4: Commit the protocol implementation**

```bash
git add Sources/AgentQueue/AgentQueueSkillSupport.swift Sources/AgentQueue/AgentQueueInstructionBuilder.swift
git commit -m "feat: add planner queue request protocol"
```

---

### Task 3: Specify Planner Response Parsing and Persistence

**Files:**
- Create: `cmuxTests/AgentQueuePlanDetectorTests.swift`
- Modify: `cmuxTests/AgentQueueModelsTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: future `AgentQueuePlanDetector.detect(in:)` and planning state values.
- Produces: parser and backward-compatible persistence requirements.

- [ ] **Step 1: Add a Swift Testing parser suite**

Create `AgentQueuePlanDetectorTests.swift` with `import Testing` and tests for:

```swift
@Test func parsesMarkedPlannerPayload() throws {
    let text = """
    noise
    [AGENT_QUEUE_TASKS]
    {"request_id":"11111111-2222-3333-4444-555555555555","tasks":[
      {"title":" Inspect repo ","body":" Read files. "},
      {"title":"Implement","body":"Change code."}
    ]}
    [/AGENT_QUEUE_TASKS]
    """
    let result = AgentQueuePlanDetector.detect(in: text)
    #expect(result == .success(AgentQueuePlannedTasks(
        requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        tasks: [
            .init(title: "Inspect repo", body: "Read files."),
            .init(title: "Implement", body: "Change code."),
        ]
    )))
}
```

Add cases for no complete marker (`nil`), malformed JSON (`.failure(.malformedJSON)`),
empty tasks (`.failure(.emptyTasks)`), and blank title/body
(`.failure(.invalidTask(index: 0))`).

- [ ] **Step 2: Add model round-trip and legacy decode tests**

Construct an `AgentQueuePlanningRequest` with phase `.waitingForPlanner`, encode
and decode `AgentQueueState`, and assert equality. Remove the `planningRequest`
key from encoded JSON and assert legacy decoding yields `nil`.

- [ ] **Step 3: Wire the new test file into the test target**

Mirror the four entries used by `AgentQueueReportDetectorTests.swift`:

- one `PBXBuildFile`
- one `PBXFileReference`
- one item in the `cmuxTests` group
- one item in the `cmuxTests` Sources phase

Run:

```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
./scripts/lint-pbxproj-test-wiring.sh
```

Expected: wiring lint PASS.

- [ ] **Step 4: Run parser/model tests and verify RED**

Run the tagged `xcodebuild` command from Task 1 with:

```text
-only-testing:cmuxTests/AgentQueuePlanDetectorTests
-only-testing:cmuxTests/AgentQueueModelsTests
```

Expected: FAIL because the detector and planning models are not implemented.

- [ ] **Step 5: Commit the red parser and persistence tests**

```bash
git add cmuxTests/AgentQueuePlanDetectorTests.swift cmuxTests/AgentQueueModelsTests.swift cmux.xcodeproj/project.pbxproj
git commit -m "test: specify planner response ingest"
```

---

### Task 4: Implement Planner Response Parser and Planning Models

**Files:**
- Create: `Sources/AgentQueue/AgentQueuePlanDetector.swift`
- Modify: `Sources/AgentQueue/AgentQueueModels.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
  - `AgentQueuePlannedTask { title: String, body: String }`
  - `AgentQueuePlannedTasks { requestID: UUID, tasks: [AgentQueuePlannedTask] }`
  - `AgentQueuePlanDetectionError`
  - `AgentQueuePlanDetector.detect(in:) -> Result<AgentQueuePlannedTasks, AgentQueuePlanDetectionError>?`
  - optional `AgentQueueState.planningRequest`

- [ ] **Step 1: Add backward-compatible planning state**

Add:

```swift
enum AgentQueuePlanningPhase: String, Codable, Equatable, Sendable {
    case submitting
    case waitingForPlanner = "waiting_for_planner"
    case failed
}

struct AgentQueuePlanningRequest: Codable, Equatable, Sendable {
    var requestID: UUID
    var goal: String
    var phase: AgentQueuePlanningPhase
    var createdAt: Date
    var errorMessage: String?
}
```

Add `var planningRequest: AgentQueuePlanningRequest? = nil` to
`AgentQueueState`. Keep it optional so synthesized decoding uses
`decodeIfPresent` and old state remains valid.

- [ ] **Step 2: Implement the focused parser**

In the new detector file, decode only the substring between the last complete
`[AGENT_QUEUE_TASKS]`/`[/AGENT_QUEUE_TASKS]` pair. Use private `Codable` wire
types, trim each field, and return the exact error cases from Task 3. Reject the
entire payload if any task is invalid.

- [ ] **Step 3: Wire the production file into the app target**

Mirror `AgentQueueReportDetector.swift` with one file reference, one build file,
one Sources group entry, and one app Sources phase entry. Normalize and run:

```bash
python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
./scripts/check-pbxproj.sh
```

- [ ] **Step 4: Run parser/model tests and verify GREEN**

Run the Task 3 focused test command. Expected: PASS.

- [ ] **Step 5: Commit parser and models**

```bash
git add Sources/AgentQueue/AgentQueuePlanDetector.swift Sources/AgentQueue/AgentQueueModels.swift cmux.xcodeproj/project.pbxproj
git commit -m "feat: parse planner queue responses"
```

---

### Task 5: Specify One Complete Prompt Submission

**Files:**
- Modify: `cmuxTests/AgentQueueControllerTests.swift`
- Modify: `cmuxTests/AgentQueuePreparationTests.swift`
- Modify: `cmuxTests/AgentQueuePaneAdapterTests.swift`

**Interfaces:**
- Consumes: future `submitText(_:to:)` adapter/driver contract.
- Produces: regression coverage for Start leaving a Codex draft and for role preparation using the same complete submission path.

- [ ] **Step 1: Change the fake pane adapter to record complete submissions**

Keep the old `sendText`/`sendEnter` fake methods so the red test still compiles,
but add the desired complete-submission method and its own record:

```swift
var submissions: [(surfaceID: UUID, text: String)] = []
var submissionError: Error?

func submitText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
    submissions.append((surfaceID, text))
    if let submissionError { throw submissionError }
    return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
}
```

Update `testStartDispatchesInstructionAndEnterToWorker` to
`testStartSubmitsCompleteInstructionToWorker` and assert exactly one worker
submission containing the task ID. Configure the legacy fake `sendEnter` path
to throw; the old split implementation therefore fails while the desired
complete-submission path succeeds. Change the failure test to inject
`submissionError` and assert dispatch failure after the production protocol is
updated.

- [ ] **Step 2: Split preparation fake records into raw shell input and prompts**

Keep the legacy driver methods for the red build, add a future `submitPrompt`
method, and record the two paths separately:

```swift
var rawShellTexts: [(surfaceID: UUID, text: String)] = []
var submittedPrompts: [(surfaceID: UUID, text: String)] = []
```

Assert `codex` appears only in `rawShellTexts` and role prompts appear only in
`submittedPrompts`.

- [ ] **Step 3: Add an adapter event-plan regression test**

Expose a pure event plan from the production adapter and assert:

```swift
#expect(AgentQueuePromptSubmission.events(for: "line 1\nline 2") == [
    .pasteText("line 1\nline 2"),
    .namedKey("return"),
])
```

This test verifies the observable terminal submission contract rather than
source text.

- [ ] **Step 4: Run focused tests and verify RED**

Run controller, preparation, and pane-adapter suites. Expected: FAIL because
the production protocols still expose split `sendText`/`sendEnter` calls.

- [ ] **Step 5: Commit the red submission regression tests**

```bash
git add cmuxTests/AgentQueueControllerTests.swift cmuxTests/AgentQueuePreparationTests.swift cmuxTests/AgentQueuePaneAdapterTests.swift
git commit -m "test: reproduce incomplete agent queue submit"
```

---

### Task 6: Implement the Unified TextBox Submission Path

**Files:**
- Modify: `Sources/TextBoxInput.swift`
- Modify: `Sources/AgentQueue/AgentQueuePaneAdapter.swift`
- Modify: `Sources/AgentQueue/AgentQueueWorkerPreparationService.swift`
- Modify: `Sources/AgentQueue/AgentQueueController.swift`

**Interfaces:**
- Produces:
  - internal async TextBox event submission returning `CompletionContext`
  - `AgentQueuePaneAdapting.submitText(_:to:)`
  - `AgentQueueWorkspaceDriving.sendRawShellText`, `sendEnter`, and `submitPrompt`

- [ ] **Step 1: Add an async TextBox event wrapper**

Add an internal `TextBoxSubmit.sendEvents(_:via:) async -> CompletionContext`
overload that wraps the existing callback runner with
`withCheckedContinuation`. It must not duplicate event dispatch logic.

- [ ] **Step 2: Add the Agent Queue prompt event plan**

Define a focused value helper in `AgentQueuePaneAdapter.swift`:

```swift
struct AgentQueuePromptSubmission {
    static func events(for text: String) -> [TextBoxSubmit.DispatchEvent] {
        [.pasteText(text), .namedKey(TextBoxTerminalKey.returnKey.rawValue)]
    }
}
```

- [ ] **Step 3: Replace the pane adapter split prompt API**

Keep explicit raw methods only for shell launch and add:

```swift
func submitText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult
```

The app implementation resolves the `TerminalPanel`, calls the async TextBox
event wrapper with `AgentQueuePromptSubmission.events(for:)`, throws when
`completion.didSubmit` is false, refreshes the surface, blocks the stale-ready
fallback, and returns one accepted result.

- [ ] **Step 4: Route preparation correctly**

Rename the driver methods to make intent explicit:

```swift
func sendRawShellText(_ text: String, to surfaceID: UUID) async throws
func sendEnter(to surfaceID: UUID) async throws
func submitPrompt(_ text: String, to surfaceID: UUID) async throws
```

Use raw text plus Enter only in `launchCodex`; use `submitPrompt` for every role
prompt.

- [ ] **Step 5: Route controller effects through `submitText`**

Replace split calls in worker dispatch, recovery, and report forwarding with one
awaited `submitText`. Map a thrown dispatch submission to the existing failure
transition; remove the obsolete local `didSendText` distinction.

- [ ] **Step 6: Run submission suites and verify GREEN**

Run the Task 5 focused tests. Expected: PASS.

- [ ] **Step 7: Commit the submission fix**

```bash
git add Sources/TextBoxInput.swift Sources/AgentQueue/AgentQueuePaneAdapter.swift \
  Sources/AgentQueue/AgentQueueWorkerPreparationService.swift Sources/AgentQueue/AgentQueueController.swift
git commit -m "fix: submit agent queue prompts with return"
```

---

### Task 7: Specify Planner Request Lifecycle and Automatic Queue Import

**Files:**
- Modify: `cmuxTests/AgentQueueControllerTests.swift`

**Interfaces:**
- Consumes: planning models, parser, and unified pane submission.
- Produces: controller behavior requirements for request, failure, polling, atomic import, and deduplication.

- [ ] **Step 1: Add request submission tests**

Add tests that call:

```swift
let accepted = await fixture.controller.requestPlan(for: "Build search")
```

Assert `accepted`, one planner submission, matching request ID in the prompt,
phase `.waitingForPlanner`, and persisted original goal. Inject a submission
error and assert `false`, phase `.failed`, and retained goal.

- [ ] **Step 2: Add planner polling/import tests**

Set the fake planner snapshot to a valid marked payload using the pending request
ID, call `pollReportsOnce`, and assert two queued tasks with trimmed title/body,
sequential mode, task-created events, and `planningRequest == nil`. Call polling
again with the same snapshot and assert the task count remains two.

- [ ] **Step 3: Add stale and malformed response tests**

Verify a wrong request ID is ignored and leaves the request waiting. Verify a
malformed matching marked payload changes the planning phase to failed and adds
no tasks.

- [ ] **Step 4: Add pending-planning monitoring coverage**

Start monitoring with no tasks but a waiting planning request, use the existing
injected short poll interval/sleep seam, and assert the planner surface was read.

- [ ] **Step 5: Run controller tests and verify RED**

Expected: FAIL because request lifecycle and planner import are not implemented.

- [ ] **Step 6: Commit the red lifecycle tests**

```bash
git add cmuxTests/AgentQueueControllerTests.swift
git commit -m "test: specify automatic planner queue import"
```

---

### Task 8: Implement Planner Request Lifecycle and Queue Import

**Files:**
- Modify: `Sources/AgentQueue/AgentQueueController.swift`

**Interfaces:**
- Produces:
  - `canRequestPlan: Bool`
  - `requestPlan(for:) async -> Bool`
  - `retryPlanningRequest() async -> Bool`
  - automatic import in `pollReportsOnce`

- [ ] **Step 1: Add readiness and pending-state gates**

`canRequestPlan` requires a ready planner record bound to the planner surface,
no submitting/waiting request, and no preparation in progress. A failed request
may be retried.

- [ ] **Step 2: Submit and persist planner requests**

Normalize the goal, create a UUID, set phase `.submitting`, persist, build the
planner request prompt, and call `paneAdapter.submitText`. On success set
`.waitingForPlanner`; on failure set `.failed` and a localized-safe internal
error message. Return whether the complete submission was accepted.

Retry creates a new UUID from the retained failed goal so a delayed old response
cannot be imported.

- [ ] **Step 3: Poll planner output whenever planning is waiting**

Change the monitor guard to continue when either active tasks exist or the
planning phase is `.waitingForPlanner`. Read the planner surface first and pass
its text to the plan detector before report detection.

- [ ] **Step 4: Import a matching response atomically**

If detection succeeds and IDs match, create all `AgentTask` values using the
existing ID factory/defaults, append task-created events, clear the planning
request, update queue time, and persist once. Ignore mismatched IDs. On a parser
failure while a complete marker is present, mark the request failed and persist
without adding tasks.

- [ ] **Step 5: Run controller tests and verify GREEN**

Run `AgentQueueControllerTests`. Expected: PASS.

- [ ] **Step 6: Commit lifecycle implementation**

```bash
git add Sources/AgentQueue/AgentQueueController.swift
git commit -m "feat: import planner tasks into agent queue"
```

---

### Task 9: Update Sidebar Planning UI and Localization

**Files:**
- Modify: `Sources/AgentQueue/AgentQueueSidebarView.swift`
- Modify: `Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `canRequestPlan`, `requestPlan(for:)`, `retryPlanningRequest()` and persisted planning phase.
- Produces: goal-oriented input UI, waiting/error state, and retry action.

- [ ] **Step 1: Route the button to the planner asynchronously**

Change the section title to `agentQueue.input.goalTitle`, the action to
`agentQueue.input.sendToPlanner`, and call:

```swift
Task {
    if await controller.requestPlan(for: taskInput) {
        taskInput = ""
    }
}
```

Disable it for empty input or `!controller.canRequestPlan`.

- [ ] **Step 2: Show waiting and failure state**

For `.submitting`/`.waitingForPlanner`, show a `ProgressView` and localized
`agentQueue.input.planning`. For `.failed`, show the error text and a localized
`agentQueue.input.retry` button invoking `retryPlanningRequest()`.

- [ ] **Step 3: Add localized strings for every catalog locale**

Add the four keys to every locale already represented by neighboring Agent Queue
keys. Use at minimum these exact translations:

```text
en: Goal input / Send to Planner / Planner is creating tasks… / Retry
ja: 目標入力 / Planner に送信 / Planner がタスクを作成中… / 再試行
ko: 목표 입력 / Planner에 보내기 / Planner가 작업을 생성하고 있습니다… / 다시 시도
```

Use the English values for catalog locales without a reviewed translation,
matching the existing Agent Queue catalog policy.

- [ ] **Step 4: Parse and audit localization**

```bash
python3 -m json.tool Resources/Localizable.xcstrings >/dev/null
rg -n 'agentQueue\.input\.(goalTitle|sendToPlanner|planning|retry)' Resources/Localizable.xcstrings
rg -n 'Text\("[A-Za-z]|Button\("[A-Za-z]' Sources/AgentQueue/AgentQueueSidebarView.swift
```

Expected: JSON parse PASS, all four keys have the same locale set as adjacent
Agent Queue keys, and no newly introduced bare English UI literal.

- [ ] **Step 5: Run Agent Queue tests and build**

Run all `AgentQueue*Tests`, then:

```bash
./scripts/reload.sh --tag agent-queue
```

Expected: tests PASS and tagged Debug build succeeds.

- [ ] **Step 6: Commit UI and localization**

```bash
git add Sources/AgentQueue/AgentQueueSidebarView.swift Resources/Localizable.xcstrings
git commit -m "feat: add planner-driven queue input UI"
```

---

### Task 10: Full Verification and Tagged Dogfood

**Files:**
- Verify only; modify production/tests only if a newly reproduced failure gets a new red test first.

**Interfaces:**
- Consumes: complete Agent Queue implementation.
- Produces: evidence for every user requirement.

- [ ] **Step 1: Run project integrity checks**

```bash
git diff --check origin/main...HEAD
./scripts/lint-pbxproj-test-wiring.sh
./scripts/check-pbxproj.sh
python3 -m json.tool Resources/Localizable.xcstrings >/dev/null
```

Expected: all commands PASS.

- [ ] **Step 2: Build and run the entire Agent Queue test set**

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-agent-queue-tests \
  -only-testing:cmuxTests/AgentQueueModelsTests \
  -only-testing:cmuxTests/AgentQueueInstructionBuilderTests \
  -only-testing:cmuxTests/AgentQueuePlanDetectorTests \
  -only-testing:cmuxTests/AgentQueueReportDetectorTests \
  -only-testing:cmuxTests/AgentQueueCoreTests \
  -only-testing:cmuxTests/AgentQueueStoreTests \
  -only-testing:cmuxTests/AgentQueuePaneAdapterTests \
  -only-testing:cmuxTests/AgentQueueControllerTests \
  -only-testing:cmuxTests/AgentQueuePreparationTests test
```

Expected: every selected suite executes at least one test and PASSes.

- [ ] **Step 3: Reload and launch the isolated app**

```bash
./scripts/reload.sh --tag agent-queue --launch
```

Expected: build succeeds and `/tmp/cmux-debug-agent-queue.sock` responds.

- [ ] **Step 4: Verify role preparation in the tagged app**

In an isolated workspace, open Agent Queue, prepare one worker, and inspect both
panes. Evidence required:

- exactly planner + one worker pane
- each receives `[AGENT_QUEUE_ROLE_START]`
- neither receives a role-end marker
- both return to Codex idle after role initialization

- [ ] **Step 5: Verify planner-driven import**

Enter a multi-step goal and click Send to Planner. Evidence required:

- planner immediately receives and submits the request
- sidebar shows planning state
- planner's structured response creates queued task rows exactly once
- the raw user goal is not directly split into tasks by the app

- [ ] **Step 6: Verify Start submits the worker task**

Click Start. Evidence required:

- worker transitions from idle to working
- no `[Pasted Content ...]` draft remains in the composer
- the instruction includes the assigned task ID
- queue status reflects dispatch/report progress

- [ ] **Step 7: Review final diff and working tree**

```bash
git status --short
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
```

Expected: only intended files changed; `.serena/` remains untracked and unstaged.
