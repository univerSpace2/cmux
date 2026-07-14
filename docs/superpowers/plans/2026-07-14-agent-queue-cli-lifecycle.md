# Agent Queue CLI Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Planner/Worker terminal-output parsing with durable Agent Queue JSON-RPC/CLI commands, immediate capacity-limited scheduling, binding-generation handshakes, and safe automatic/manual registration removal.

**Architecture:** `AgentQueueCoordinator` becomes a Swift actor and the only durable mutation boundary. It validates caller/binding context, applies pure `AgentQueueCore` transitions, performs an atomic file commit before publishing immutable state/effect streams, and leaves main-actor pane work to `AgentQueueEffectExecutor`; `AgentQueueController` is only an Observation façade. `CmuxControlSocket` owns transport DTO validation while an async app bridge routes calls through an injected coordinator registry without selecting or focusing UI.

**Tech Stack:** Swift 6, Observation, actors and `AsyncStream`, Foundation `Codable`/JSON, CryptoKit SHA-256, existing Unix-domain socket JSON-RPC v2, Swift Testing, SwiftUI, Xcode 26.

## Global Constraints

- Implement the approved contract in `docs/superpowers/specs/2026-07-14-agent-queue-cli-lifecycle-design.md`; do not add HTTP, file-drop ingest, terminal-output fallback, automatic pane recreation, or active-task reassignment.
- Planner uses `cmux agent-queue enqueue --stdin`; Workers use `cmux agent-queue report --task TASK_ID --report REPORT_ID --status STATUS --binding BINDING_ID --stdin`; stdin bytes decode as UTF-8 exactly once.
- Valid enqueue schedules immediately only when queue is already running. Pause is sticky; enqueue, restore, reconcile, and re-prepare never resume it.
- Capacity is current-binding `ready + surface-present + idle + enabled` Workers. Preserve FIFO and the existing sequential barrier.
- Ready handshake deadline is 30 seconds. Every preparation attempt generates a new `binding_id`; stale ready/offline/report calls cannot affect a replacement binding.
- Automatic and manual removal call the same coordinator operation. Removal unregisters only; it never closes a pane or terminates Codex.
- Active Worker loss/timeout/manual removal blocks its task and pauses. Idle Worker loss removes capacity and continues. Planner loss clears its surface, marks it `notReady`, and pauses.
- Parse/validate/persist Agent Queue socket calls off-main. No Agent Queue socket call may activate cmux, raise a window, select a workspace, focus a pane, or change a selected surface.
- New mutable shared state uses actors. Do not add `DispatchQueue` serialization, locks, semaphores, `@unchecked Sendable`, `nonisolated(unsafe)`, Combine, or polling sleeps. The existing dedicated-thread `v2AsyncResultCall` may bridge the new async package handler; do not add another blocking bridge.
- Every new major Swift type gets its own file. Every new package `public` symbol gets DocC comments and an injected test seam.
- Keep list rows below `LazyVStack`/`ForEach` boundaries value-only: immutable snapshots plus closures, never controller/store references.
- Localize every new UI/CLI/help/error string in `Resources/Localizable.xcstrings` for English and Japanese. Preserve the pre-existing unstaged catalog edits and add only the new keys.
- Preserve unstaged edits in `Sources/AgentQueue/AgentQueueInstructionBuilder.swift`, `cmuxTests/AgentQueueControllerTests.swift`, and `cmuxTests/AgentQueueInstructionBuilderTests.swift`; merge around them, never replace or delete them.
- Do not stage `.serena/`.
- Behavioral regression tests land in a red test-only commit before the production fix. New `cmuxTests` files require `PBXFileReference`, `PBXBuildFile`, group, and Sources-phase entries.
- All shell commands in this plan use `rtk`. Final build command is exactly `rtk ./scripts/reload.sh --tag agent-queue-planner-ingest`; never launch an untagged Debug app.

## File Responsibility Map

- `Sources/AgentQueue/AgentQueueModels.swift`: existing queue/task/worker/state values and backward decode cases only.
- `Sources/AgentQueue/AgentQueueAgentRole.swift`, `AgentQueueAgentReadiness.swift`, `AgentQueueAgentBinding.swift`: generation-aware role registration.
- `Sources/AgentQueue/AgentQueueSubmission.swift`, `AgentQueueTaskReport.swift`, `AgentQueueProtocolRequest.swift`: idempotency/audit records and typed command payloads.
- `Sources/AgentQueue/AgentQueueStateMigration.swift`: value-typed v1 decode and one-way, idempotent v2 migration.
- `Sources/AgentQueue/AgentQueueCore.swift`: pure scheduler/reducer; no persistence, pane access, or terminal reads.
- `Sources/AgentQueue/AgentQueueCoordinator.swift`: actor-owned state, command authorization, atomic commit ordering, state/effect streams.
- `Sources/AgentQueue/AgentQueueFilePersistence.swift`: injected synchronous filesystem seam called only inside the coordinator actor.
- `Sources/AgentQueue/AgentQueueEffectExecutor.swift`: main-actor prompt/recovery dispatch and result callbacks.
- `Sources/AgentQueue/AgentQueueController.swift`: `@MainActor @Observable` UI façade and preparation orchestration.
- `Sources/AgentQueue/AgentQueueCoordinatorRegistry.swift`: actor mapping workspace IDs to coordinators for socket/lifecycle routing.
- `Sources/AgentQueue/AgentQueueCLIInstructionBuilder.swift`: shell-safe bootstrap, ready/offline, task, and recovery instructions; leaves the currently edited legacy builder intact.
- `Sources/AgentQueue/AgentQueueTopologyReconciler.swift`: surface-close, app-active, process-ended, restore, and 10-second safety reconciliation.
- `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/AgentQueue/`: transport-only Agent Queue DTOs, context seam, and handler.
- `Sources/TerminalController+ControlAgentQueueContext.swift`: async package-to-app bridge only.
- `CLI/CMUXCLI+AgentQueue.swift`: thin CLI parser/stdin mapper; no queue decisions.
- `skills/cmux-agent-queue-planner/SKILL.md`, `skills/cmux-agent-queue-worker/SKILL.md`: CLI-only Planner enqueue and Worker report contracts.

---

### Task 1: Lock Versioned Persistence and Exact Payload Requirements

**Files:**
- Create: `cmuxTests/AgentQueueStateMigrationTests.swift`
- Create: `cmuxTests/AgentQueuePayloadRoundTripTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: current v1 `AgentQueueState` JSON shape and future `AgentQueueStateMigration().decode(_:)`.
- Produces: executable v2 schema/migration and exact-string preservation requirements used by every later task.

- [ ] **Step 1: Add the migration regression suite**

Create a Swift Testing suite whose v1 fixture contains each legacy in-flight status and a ready preparation record. Pin these assertions:

```swift
import Foundation
import Testing

@Suite struct AgentQueueStateMigrationTests {
    @Test(arguments: ["dispatching", "dispatched", "awaiting_report", "retrying"])
    func legacyInFlightTaskBecomesBlocked(_ status: String) throws {
        let data = AgentQueueMigrationFixture.v1(taskStatus: status)
        let state = try AgentQueueStateMigration().decode(data)
        let task = try #require(state.tasks.first)
        #expect(state.schemaVersion == AgentQueueState.currentSchemaVersion)
        #expect(task.status == .blocked)
        #expect(task.lastError == "Blocked during Agent Queue protocol migration; inspect before retrying.")
        #expect(state.queue.status == .paused)
        #expect(state.bindings.allSatisfy { $0.readiness == .notReady })
    }

    @Test(arguments: ["queued", "completed", "failed", "blocked", "cancelled"])
    func legacySafeTaskStatusIsPreserved(_ status: String) throws {
        let state = try AgentQueueStateMigration().decode(
            AgentQueueMigrationFixture.v1(taskStatus: status)
        )
        #expect(state.tasks.first?.status.rawValue == status)
    }

    @Test func migrationIsIdempotent() throws {
        let once = try AgentQueueStateMigration().decode(
            AgentQueueMigrationFixture.v1(taskStatus: "awaiting_report")
        )
        let encoded = try JSONEncoder.agentQueue.encode(once)
        let twice = try AgentQueueStateMigration().decode(encoded)
        #expect(twice == once)
    }
}
```

Implement `AgentQueueMigrationFixture.v1(taskStatus:)` in the same test file as a private value builder that serializes a full current-v1 dictionary. It must include `planningRequest`, planner `surfaceID`, worker `surfaceID`, and a ready record so the test proves those protocol-era fields are discarded/invalidated.

- [ ] **Step 2: Add exact special-character round-trip tests**

Create a second Swift Testing suite using this exact payload:

````swift
private let exactBody = """
Quotes: "double" and 'single'
Paths: C:\\Users\\agent\\repo and \\server\\share
Escapes: literal \\n \\t \\u1234
Tabs:	between
Unicode: 작업 計画 🚀
```swift
let value = "\\\"quoted\\\""
```
"""

@Suite struct AgentQueuePayloadRoundTripTests {
    @Test func submissionAndReportPreserveExactText() throws {
        let request = AgentQueueEnqueueRequest(
            submissionID: "sub-special-1",
            tasks: [.init(
                title: "Parser \\ \"quotes\" 작업",
                body: exactBody,
                executionMode: .parallelAllowed,
                timeoutSeconds: 1_800,
                retryLimit: 1
            )]
        )
        let requestCopy = try JSONDecoder.agentQueue.decode(
            AgentQueueEnqueueRequest.self,
            from: JSONEncoder.agentQueue.encode(request)
        )
        #expect(requestCopy == request)

        let report = AgentQueueTaskReport(
            reportID: "report-special-1",
            taskID: "T-20260714-0001",
            status: .completed,
            body: exactBody,
            bindingID: "binding-worker-1",
            attemptNumber: 1,
            reportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let reportCopy = try JSONDecoder.agentQueue.decode(
            AgentQueueTaskReport.self,
            from: JSONEncoder.agentQueue.encode(report)
        )
        #expect(reportCopy == report)
    }
}
````

- [ ] **Step 3: Wire both tests and prove RED**

Add all four pbxproj entries for both test files, then run:

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk ./scripts/lint-pbxproj-test-wiring.sh
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueStateMigrationTests -only-testing:cmuxTests/AgentQueuePayloadRoundTripTests
```

Expected: wiring lint passes; compile fails because migration/protocol types do not exist.

- [ ] **Step 4: Commit red regression tests only**

```bash
rtk git add cmuxTests/AgentQueueStateMigrationTests.swift cmuxTests/AgentQueuePayloadRoundTripTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "test: specify agent queue CLI persistence contract"
```

---

### Task 2: Add Durable Binding, Submission, Report, and Migration Models

**Files:**
- Create: `Sources/AgentQueue/AgentQueueAgentRole.swift`
- Create: `Sources/AgentQueue/AgentQueueAgentReadiness.swift`
- Create: `Sources/AgentQueue/AgentQueueAgentBinding.swift`
- Create: `Sources/AgentQueue/AgentQueueSubmission.swift`
- Create: `Sources/AgentQueue/AgentQueueReportStatus.swift`
- Create: `Sources/AgentQueue/AgentQueueTaskReport.swift`
- Create: `Sources/AgentQueue/AgentQueueProtocolRequest.swift`
- Create: `Sources/AgentQueue/AgentQueueStateMigration.swift`
- Modify: `Sources/AgentQueue/AgentQueueModels.swift`
- Modify: `Sources/AgentQueue/AgentQueuePreparationModels.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: v1 persisted JSON and Task 1 expectations.
- Produces: `AgentQueueState.currentSchemaVersion == 2`, binding generation records, typed enqueue/report requests, and idempotent migration.

- [ ] **Step 1: Define one type per file with these exact contracts**

```swift
enum AgentQueueAgentRole: String, Codable, Equatable, Sendable { case planner, worker }
enum AgentQueueAgentReadiness: String, Codable, Equatable, Sendable { case pending, ready, notReady = "not_ready" }

struct AgentQueueAgentBinding: Identifiable, Codable, Equatable, Sendable {
    var id: String { bindingID }
    var bindingID: String
    var agentID: String
    var role: AgentQueueAgentRole
    var workspaceID: UUID
    var paneID: UUID?
    var surfaceID: UUID?
    var readiness: AgentQueueAgentReadiness
    var preparedAt: Date
    var readyDeadline: Date?
    var readyAt: Date?
    var lastSeenAt: Date?
    var observedSessionID: String?
}

struct AgentQueueSubmission: Identifiable, Codable, Equatable, Sendable {
    var id: String { submissionID }
    var submissionID: String
    var payloadDigest: String
    var taskIDs: [String]
    var createdAt: Date
}

enum AgentQueueReportStatus: String, Codable, Equatable, Sendable {
    case completed, failed, blocked
}

struct AgentQueueTaskReport: Identifiable, Codable, Equatable, Sendable {
    var id: String { reportID }
    var reportID: String
    var taskID: String
    var status: AgentQueueReportStatus
    var body: String
    var bindingID: String
    var attemptNumber: Int
    var reportedAt: Date
}
```

`AgentQueueProtocolRequest.swift` contains value-only request DTOs:

```swift
struct AgentQueueCallerContext: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var surfaceID: UUID
}

struct AgentQueueTaskDraft: Codable, Equatable, Sendable {
    var title: String
    var body: String
    var executionMode: AgentTaskExecutionMode
    var timeoutSeconds: TimeInterval
    var retryLimit: Int
}

struct AgentQueueEnqueueRequest: Codable, Equatable, Sendable {
    var submissionID: String
    var tasks: [AgentQueueTaskDraft]
}

struct AgentQueueReportRequest: Codable, Equatable, Sendable {
    var taskID: String
    var reportID: String
    var status: AgentQueueReportStatus
    var bindingID: String
    var body: String
}
```

Use custom coding keys so CLI JSON names are `submission_id`, `execution_mode`, `timeout_seconds`, `retry_limit`, `task_id`, `report_id`, `binding_id`. Decode `execution_mode: "parallel"` to `.parallelAllowed`; migration also accepts legacy `"parallel_allowed"`.

- [ ] **Step 2: Make v2 state explicit**

Change `AgentQueueState` to:

```swift
struct AgentQueueState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var revision: UInt64
    var queue: AgentQueue
    var tasks: [AgentTask]
    var workers: [AgentWorker]
    var bindings: [AgentQueueAgentBinding]
    var submissions: [AgentQueueSubmission]
    var reports: [AgentQueueTaskReport]
    var events: [AgentQueueLogEvent]
    var preparation: AgentQueuePreparationState?
}
```

Remove `planningRequest` from v2 state. Remove `plannerSurfaceID` from `AgentQueue`; v1 decoding belongs only in `AgentQueueStateMigration`. Add `bindingID: String?` to `AgentWorker`; v2-created Workers always have it, while migration decodes old Workers with `nil` and marks them offline/not ready.

- [ ] **Step 3: Implement idempotent v1-to-v2 migration**

`AgentQueueStateMigration().decode(_:)` first reads a version probe. Version 2 decodes directly and rejects future versions. Version 1 decodes private `LegacyAgentQueueStateV1` values and applies this exact mapping:

```swift
struct AgentQueueStateMigration: Sendable {
    func schemaVersion(in data: Data) throws -> Int
    func decode(_ data: Data) throws -> AgentQueueState
}
```

```swift
switch legacyTask.status {
case .dispatching, .dispatched, .awaitingReport, .retrying:
    task.status = .blocked
    task.lastError = "Blocked during Agent Queue protocol migration; inspect before retrying."
    migratedInFlight = true
case .queued, .completed, .blocked, .failed, .cancelled:
    break
}
```

Create one Planner binding from the legacy planner surface and one binding per legacy Worker, but set every binding to `.notReady`, clear every Worker `bindingID`, set every Worker status `.offline`, discard planning request/fingerprints, set revision `0`, and pause when Planner is not ready or an in-flight task changed. Return schema version 2.

- [ ] **Step 4: Wire production files and verify GREEN**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk ./scripts/check-pbxproj.sh
rtk ./scripts/lint-pbxproj-test-wiring.sh
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueStateMigrationTests -only-testing:cmuxTests/AgentQueuePayloadRoundTripTests
```

Expected: both suites execute and pass.

- [ ] **Step 5: Commit model/migration fix**

```bash
rtk git add Sources/AgentQueue/AgentQueueAgentRole.swift Sources/AgentQueue/AgentQueueAgentReadiness.swift Sources/AgentQueue/AgentQueueAgentBinding.swift Sources/AgentQueue/AgentQueueSubmission.swift Sources/AgentQueue/AgentQueueReportStatus.swift Sources/AgentQueue/AgentQueueTaskReport.swift Sources/AgentQueue/AgentQueueProtocolRequest.swift Sources/AgentQueue/AgentQueueStateMigration.swift Sources/AgentQueue/AgentQueueModels.swift Sources/AgentQueue/AgentQueuePreparationModels.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "feat: version agent queue bindings and protocol records"
```

---

### Task 3: Replace Start/Screen Events with Pure CLI and Lifecycle Transitions

**Files:**
- Modify: `Sources/AgentQueue/AgentQueueCore.swift`
- Modify: `cmuxTests/AgentQueueCoreTests.swift`

**Interfaces:**
- Consumes: v2 state/types from Task 2.
- Produces: complete pure reducer/scheduler semantics used by coordinator, UI, lifecycle, timeout, and effect callbacks.

- [ ] **Step 1: Replace reducer events/effects with the exact enum surface**

```swift
enum AgentQueueInputEvent: Equatable, Sendable {
    case tasksEnqueued(tasks: [AgentTask], submission: AgentQueueSubmission)
    case queuePaused(cause: String)
    case queueResumed
    case bindingsPrepared([AgentQueueAgentBinding])
    case agentReady(bindingID: String)
    case agentRemoved(agentID: String, bindingID: String?, cause: String)
    case dispatchSubmitted(taskID: String, workerID: String, bindingID: String, queued: Bool)
    case dispatchSubmissionFailed(taskID: String, workerID: String, bindingID: String, message: String)
    case taskReported(AgentQueueTaskReport)
    case recoverySubmitted(taskID: String, workerID: String, bindingID: String)
    case recoverySubmissionFailed(taskID: String, workerID: String, bindingID: String, message: String)
    case taskTimedOut(taskID: String, bindingID: String)
    case taskCancelled(taskID: String)
}

enum AgentQueueSideEffect: Equatable, Sendable {
    case dispatch(taskID: String, workerID: String, bindingID: String)
    case recover(taskID: String, workerID: String, bindingID: String)
}

struct AgentQueueCore: Sendable {
    func reduce(state: AgentQueueState, event: AgentQueueInputEvent, now: Date) -> AgentQueueReduceResult
}
```

Remove `.queueStarted`, screen-report events, forwarding, and `.persist`; coordinator persistence wraps every transition.

- [ ] **Step 2: Add behavioral scheduler tests before reducer edits**

Add tests using fixed dates/bindings for:

```swift
@Test func enqueueFillsOnlyReadyLiveIdleCapacity() {
    var fixture = AgentQueueCoreFixture.make(taskCount: 3, workerCount: 3)
    fixture.state.workers[2].bindingID = nil
    let submission = fixture.submission(taskIDs: fixture.state.tasks.map(\.id))
    let result = AgentQueueCore().reduce(
        state: fixture.state,
        event: .tasksEnqueued(tasks: [], submission: submission),
        now: fixture.now
    )
    #expect(result.effects == [
        .dispatch(taskID: "T-20260709-0001", workerID: "worker-1", bindingID: "binding-worker-1"),
        .dispatch(taskID: "T-20260709-0002", workerID: "worker-2", bindingID: "binding-worker-2"),
    ])
    #expect(result.state.tasks[2].status == .queued)
}

@Test func enqueueWhilePausedDoesNotResume() {
    var fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)
    fixture.state.queue.status = .paused
    let task = fixture.task(id: "T-20260709-0001", mode: .parallelAllowed)
    let result = AgentQueueCore().reduce(
        state: fixture.state,
        event: .tasksEnqueued(tasks: [task], submission: fixture.submission(taskIDs: [task.id])),
        now: fixture.now
    )
    #expect(result.state.queue.status == .paused)
    #expect(result.state.tasks == [task])
    #expect(result.effects.isEmpty)
}

@Test func activeWorkerRemovalBlocksAndPauses() {
    var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
    fixture.assign(taskIndex: 0, workerIndex: 0)
    let result = AgentQueueCore().reduce(
        state: fixture.state,
        event: .agentRemoved(agentID: "worker-1", bindingID: "binding-worker-1", cause: "surface_closed"),
        now: fixture.now
    )
    #expect(result.state.tasks[0].status == .blocked)
    #expect(result.state.queue.status == .paused)
    #expect(result.state.workers.isEmpty)
    #expect(result.effects.isEmpty)
}
```

Migrate this touched suite from XCTest to Swift Testing. Add fixture helpers with these exact signatures and fixed IDs: `make(taskCount:workerCount:)`, `task(id:mode:)`, `submission(taskIDs:)`, and mutating `assign(taskIndex:workerIndex:)`. Add separate tests for the remaining cases with these exact expected outcomes: a sequential task produces only its own dispatch until it completes; completion produces the next queued dispatch; first failed report at retry limit 1 produces one `.recover` for the same binding and count 1; the next distinct failed report makes task `.failed`, releases Worker, and pauses; idle Worker removal leaves queue status unchanged; Planner removal retains one Planner binding with `surfaceID == nil` and `.notReady`; timeout blocks task, removes Worker/binding, and pauses.

- [ ] **Step 3: Run tests to verify RED**

```bash
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueCoreTests
```

Expected: failures show old Start/awaiting-report/timeout behavior.

- [ ] **Step 4: Implement the minimal reducer and eligibility predicate**

Eligibility must be one function:

```swift
private func eligibleWorkerIndices(in state: AgentQueueState) -> [Int] {
    state.workers.indices.filter { index in
        let worker = state.workers[index]
        guard worker.enabled, worker.status == .idle, worker.currentTaskID == nil,
              let bindingID = worker.bindingID,
              let binding = state.bindings.first(where: { $0.bindingID == bindingID }) else { return false }
        return binding.role == .worker && binding.readiness == .ready && binding.surfaceID == worker.surfaceID
    }
}
```

`tasksEnqueued` appends the whole batch/submission, updates time, and schedules only when status is `.running`. `taskReported(.completed)` stores the report, completes the task, releases the Worker, then schedules. `.failed` increments recovery only when `recoveryAttemptCount < retryLimit` and emits `.recover` for the same binding; otherwise it fails/releases/pauses. `.blocked` blocks/releases/pauses. Removal uses role and active assignment to apply the approved table.

- [ ] **Step 5: Verify GREEN and commit**

Run the Task 3 command. Expected: suite passes with nonzero executed count.

```bash
rtk git add Sources/AgentQueue/AgentQueueCore.swift cmuxTests/AgentQueueCoreTests.swift
rtk git commit -m "feat: schedule agent queue from CLI lifecycle events"
```

---

### Task 4: Add Atomic Persistence and the Serialized Coordinator Actor

**Files:**
- Create: `Sources/AgentQueue/AgentQueuePersisting.swift`
- Create: `Sources/AgentQueue/AgentQueueFilePersistence.swift`
- Create: `Sources/AgentQueue/AgentQueueCoordinatorError.swift`
- Create: `Sources/AgentQueue/AgentQueueCoordinator.swift`
- Create: `cmuxTests/AgentQueueCoordinatorTests.swift`
- Modify: `Sources/AgentQueue/AgentQueueStore.swift`
- Modify: `cmuxTests/AgentQueueStoreTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: pure `AgentQueueCore.reduce` and versioned state.
- Produces: actor methods for every RPC/UI/lifecycle path, durable-before-publish ordering, idempotency, and state/effect streams.

- [ ] **Step 1: Define persistence and coordinator APIs**

```swift
protocol AgentQueuePersisting: Sendable {
    func load(persistenceID: UUID, legacyWorkspaceID: UUID?) throws -> Data?
    func save(_ data: Data, persistenceID: UUID) throws
    func removeLegacyState(workspaceID: UUID) throws
}

actor AgentQueueCoordinator {
    init(workspaceID: UUID, persistenceID: UUID, legacyWorkspaceID: UUID?, initialState: AgentQueueState, persistence: any AgentQueuePersisting, migration: AgentQueueStateMigration = .init(), core: AgentQueueCore = .init(), now: @escaping @Sendable () -> Date = Date.init)
    func restore() throws
    func snapshot() -> AgentQueueState
    func stateUpdates() -> AsyncStream<AgentQueueState>
    func effects() -> AsyncStream<AgentQueueSideEffect>
    func enqueue(_ request: AgentQueueEnqueueRequest, caller: AgentQueueCallerContext) throws -> AgentQueueEnqueueResult
    func report(_ request: AgentQueueReportRequest, caller: AgentQueueCallerContext) throws -> AgentQueueReportResult
    func prepareBindings(_ bindings: [AgentQueueAgentBinding]) throws
    func markReady(agentID: String, role: AgentQueueAgentRole, bindingID: String, caller: AgentQueueCallerContext) throws -> AgentQueueAgentBinding
    func markOffline(agentID: String, bindingID: String, caller: AgentQueueCallerContext?, cause: String) throws
    func removeAgent(agentID: String, expectedBindingID: String?, cause: String) throws
    func reconcile(liveSurfaceIDs: Set<UUID>, endedBindingIDs: Set<String>, cause: String) throws
    func pause(cause: String) throws
    func resume() throws
    func recordDispatch(taskID: String, workerID: String, bindingID: String, result: Result<AgentQueueSendResult, AgentQueueEffectFailure>) throws
    func recordRecovery(taskID: String, workerID: String, bindingID: String, result: Result<AgentQueueSendResult, AgentQueueEffectFailure>) throws
}
```

`AgentQueueEnqueueResult` contains `submissionID`, `taskIDs`, `revision`, `idempotent`; `AgentQueueReportResult` contains `reportID`, `taskID`, `status`, `revision`, `idempotent`.

- [ ] **Step 2: Implement true replacement and failure injection**

`persistenceID` is `Workspace.stableId`; runtime caller/binding validation still uses the fresh `Workspace.id`. `load` first checks the stable-ID file. Only when it is absent and `legacyWorkspaceID` is non-nil may it read the old runtime-workspace-ID file. Coordinator restore rewrites `queue.workspaceID` and every binding's `workspaceID` to the current runtime ID, applies lifecycle migration, atomically saves under the stable ID, then removes the legacy file. This makes startup restoration work without reusing process-local workspace IDs and prevents a manually reopened duplicate that did not adopt the snapshot stable ID from claiming the old queue.

`AgentQueueFilePersistence.save` creates the directory, writes a uniquely named temporary sibling, then calls `FileManager.replaceItemAt` when the destination exists or `moveItem` when it does not. A `defer` removes a leftover temp. Never remove the destination before replacement. `removeLegacyState` is called only after the stable file commit succeeds and is a no-op when both IDs are equal.

Keep `AgentQueueStore` as a deprecated decode adapter only long enough for existing callers/tests; route new runtime construction to `AgentQueueFilePersistence` and delete the adapter in Task 13.

- [ ] **Step 3: Add coordinator behavior tests**

Use an in-memory `RecordingAgentQueuePersistence` that records saved `Data` and can throw. Cover:

```swift
@Test func identicalSubmissionReturnsOriginalTaskIDsWithoutSavingAgain() async throws
@Test func conflictingSubmissionIDThrowsConflictWithoutMutation() async throws
@Test func invalidTaskRejectsWholeBatch() async throws
@Test func onlyCurrentReadyPlannerSurfaceCanEnqueue() async throws
@Test func duplicateFailedReportDoesNotConsumeAnotherRetry() async throws
@Test func staleBindingReadyOfflineAndReportCannotMutateReplacement() async throws
@Test func persistenceFailurePublishesNoStateAndYieldsNoEffects() async throws
@Test func committedStateIsObservedBeforeDispatchEffect() async throws
@Test func concurrentCommandsCommitStrictlyIncreasingRevisions() async throws
```

The persistence-failure test captures one `stateUpdates()` iterator and one `effects()` iterator before enqueue, injects a save error, and proves neither stream yields a post-command value.

- [ ] **Step 4: Implement one commit function**

Every mutation uses this actor-isolated synchronous-I/O sequence:

```swift
private func commit(_ event: AgentQueueInputEvent) throws -> AgentQueueReduceResult {
    var reduced = core.reduce(state: state, event: event, now: now())
    reduced.state.schemaVersion = AgentQueueState.currentSchemaVersion
    reduced.state.revision = state.revision + 1
    let data = try JSONEncoder.agentQueue.encode(reduced.state)
    try persistence.save(data, workspaceID: reduced.state.queue.workspaceID)
    state = reduced.state
    stateContinuations.values.forEach { $0.yield(state) }
    reduced.effects.forEach { effect in effectContinuations.values.forEach { $0.yield(effect) } }
    return reduced
}
```

Validation and digest computation occur before `commit`. SHA-256 hashes `JSONEncoder` output with `.sortedKeys`; identical semantic DTOs share a digest. Duplicate submission/report returns its stored result without save/reducer/effect. A conflicting key throws `.conflict`. `restore()` calls the injected migration value's `schemaVersion(in:)` before `decode(_:)` and immediately persists only when that value is 1.

Authorization is exact: enqueue requires the ready Planner binding whose workspace/surface equal caller; report requires the ready Worker binding assigned to that task and caller; ready requires a pending binding with matching agent/role/workspace/surface; offline requires the same current binding when caller context is available. CLI list/remove/reconcile/pause/resume require the current ready Planner caller, while direct controller/lifecycle methods use their injected workspace coordinator and do not fabricate caller context.

- [ ] **Step 5: Wire, run, and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk ./scripts/lint-pbxproj-test-wiring.sh
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueCoordinatorTests -only-testing:cmuxTests/AgentQueueStoreTests
rtk git add Sources/AgentQueue/AgentQueuePersisting.swift Sources/AgentQueue/AgentQueueFilePersistence.swift Sources/AgentQueue/AgentQueueCoordinatorError.swift Sources/AgentQueue/AgentQueueCoordinator.swift Sources/AgentQueue/AgentQueueStore.swift cmuxTests/AgentQueueCoordinatorTests.swift cmuxTests/AgentQueueStoreTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "feat: serialize durable agent queue commands"
```

Expected: coordinator/store suites pass; every selected suite executes tests.

---

### Task 5: Execute Effects and Convert the Controller to an Observation Façade

**Files:**
- Create: `Sources/AgentQueue/AgentQueueEffectExecutor.swift`
- Create: `Sources/AgentQueue/AgentQueueCoordinatorRegistry.swift`
- Create: `cmuxTests/AgentQueueEffectExecutorTests.swift`
- Modify: `Sources/AgentQueue/AgentQueueController.swift`
- Modify carefully: `cmuxTests/AgentQueueControllerTests.swift` (preserve existing unstaged hunks)
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: coordinator state/effect streams and existing pane adapter submission.
- Produces: main-actor effect execution, async UI façade, and workspace registry.

- [ ] **Step 1: Add value-only effect execution**

```swift
@MainActor
final class AgentQueueEffectExecutor {
    init(coordinator: AgentQueueCoordinator, paneAdapter: any AgentQueuePaneAdapting, instructionBuilder: AgentQueueCLIInstructionBuilder = .init())
    func start()
    func stop()
}
```

For `.dispatch`, fetch one coordinator snapshot, guard task/Worker/current binding still match, call the injected instruction builder's `workerInstruction`, call `paneAdapter.submitText`, then call `recordDispatch`. `.recover` follows the same validation with `recoveryInstruction` and calls `recordRecovery`. Never focus/select before submission. Store/cancel the stream task in `start`/`stop`.

- [ ] **Step 2: Add registry actor**

```swift
actor AgentQueueCoordinatorRegistry {
    func register(_ coordinator: AgentQueueCoordinator, workspaceID: UUID)
    func unregister(workspaceID: UUID)
    func coordinator(workspaceID: UUID) -> AgentQueueCoordinator?
    func allCoordinators() -> [UUID: AgentQueueCoordinator]
}
```

- [ ] **Step 3: Convert controller state propagation**

Replace Combine with:

```swift
import Observation

@MainActor @Observable
final class AgentQueueController {
    private(set) var state: AgentQueueState
    private(set) var pendingRoleSkillChanges: [AgentQueueRoleSkillChange] = []
    @ObservationIgnored private let coordinator: AgentQueueCoordinator
    @ObservationIgnored private let effectExecutor: AgentQueueEffectExecutor
    @ObservationIgnored private var stateTask: Task<Void, Never>?

    func start() {
        effectExecutor.start()
        stateTask = Task { [weak self, coordinator] in
            for await snapshot in await coordinator.stateUpdates() {
                guard !Task.isCancelled else { return }
                self?.state = snapshot
            }
        }
    }

    func pause() { Task { try? await coordinator.pause(cause: "manual") } }
    func resume() { Task { try? await coordinator.resume() } }
    func removeRegistration(agentID: String) {
        Task { try? await coordinator.removeAgent(agentID: agentID, expectedBindingID: nil, cause: "manual") }
    }
}
```

Delete `startMonitoring`, `pollReportsOnce`, report/planner fingerprints, debounced `persistSoon`, and reducer mutation from the controller. Profile editing remains UI-local preparation configuration committed through a typed coordinator operation, not direct `state` mutation.

Factory-created v2 queues start with `queue.status == .running`, zero tasks, and no bindings. Restored safety-paused state stays paused; factory/controller startup never calls `resume()`.

- [ ] **Step 4: Test effect freshness and façade projection**

Cover successful prompt submission, submission failure causing block/pause, stale effect ignored after binding replacement, recovery prompt targeting the same Worker, state stream updating controller, and registry lookup. Existing controller tests must be migrated to the coordinator fixture while preserving the current local malformed-JSON regression hunks until Task 12 removes their obsolete runtime assertions.

- [ ] **Step 5: Run and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueEffectExecutorTests -only-testing:cmuxTests/AgentQueueControllerTests
rtk git add Sources/AgentQueue/AgentQueueEffectExecutor.swift Sources/AgentQueue/AgentQueueCoordinatorRegistry.swift Sources/AgentQueue/AgentQueueController.swift cmuxTests/AgentQueueEffectExecutorTests.swift cmuxTests/AgentQueueControllerTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "refactor: project agent queue actor state into UI"
```

Expected: suites pass and no Agent Queue production file imports Combine.

---

### Task 6: Generate Bindings Before Bootstrap and Require Ready Handshakes

**Files:**
- Create: `Sources/AgentQueue/AgentQueueCLIInstructionBuilder.swift`
- Create: `cmuxTests/AgentQueueHandshakePreparationTests.swift`
- Modify: `Sources/AgentQueue/AgentQueuePaneAdapter.swift`
- Modify: `Sources/AgentQueue/AgentQueueWorkerPreparationService.swift`
- Modify: `Sources/AgentQueue/AgentQueuePreparationModels.swift`
- Modify: `cmuxTests/AgentQueuePaneAdapterTests.swift`
- Modify: `cmuxTests/AgentQueuePreparationTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: coordinator binding APIs and existing process/shell readiness signals.
- Produces: generation-aware bootstrap, 30-second handshake, no terminal-text readiness, and unregister-only downsizing.

- [ ] **Step 1: Define shell-safe bootstrap builders**

```swift
struct AgentQueueCLIInstructionBuilder: Sendable {
    func bootstrap(
        agentID: String,
        role: AgentQueueAgentRole,
        bindingID: String,
        profile: AgentQueueAgentProfile
    ) -> String

    func launchCommand(
        agentID: String,
        bindingID: String
    ) -> String

    func workerInstruction(task: AgentTask, bindingID: String, profile: AgentQueueAgentProfile) -> String
    func recoveryInstruction(task: AgentTask, bindingID: String, profile: AgentQueueAgentProfile) -> String
}
```

Bootstrap starts with the exact command:

```text
cmux agent-queue agent ready --agent worker-1 --role worker --binding 11111111-2222-3333-4444-555555555555
```

Then invokes the role skill and role prompt. `launchCommand` resolves `CMUX_BUNDLED_CLI_PATH`, runs `codex`, captures its exit status, invokes `cmux agent-queue agent offline --agent worker-1 --binding 11111111-2222-3333-4444-555555555555` for that generated identity, and exits with the original status. Implement shell single-quote escaping in the builder; never interpolate unescaped profile/task text into a shell command.

- [ ] **Step 2: Remove screen-text readiness from the adapter**

Delete `AgentQueueSurfaceTextSnapshot`, `readText`, `visibleText`, `visibleReadyFallbackBlockedSurfaceIDs`, and `visibleText.contains("OpenAI Codex")`. Keep process transcript state plus shell activity only:

```swift
struct AgentQueueCodexReadinessClassifier: Sendable {
    func classify(
        observedState: AgentQueueObservedCodexState?,
        shellActivity: AgentQueueShellActivity
    ) -> AgentQueueCodexReadiness {
        switch observedState {
        case .idle: return .idle
        case .working, .needsInput: return .busy
        case nil: return shellActivity == .promptIdle ? .absent : .starting
        }
    }
}
```

- [ ] **Step 3: Split preparation into topology, registration, and bootstrap**

Refactor the service to:

```swift
func prepareTopology(
    configuration: AgentQueuePreparationConfiguration,
    plannerSurfaceID: UUID,
    existingWorkerSlots: [AgentQueueWorkerSlot],
    activeWorkerAgentIDs: Set<String>
) async throws -> AgentQueuePreparedTopology

func bootstrap(
    topology: AgentQueuePreparedTopology,
    bindings: [AgentQueueAgentBinding],
    configuration: AgentQueuePreparationConfiguration
) async -> [AgentQueueAgentPreparationFailure]
```

Controller flow is: create/reuse topology without focus, generate a UUID binding for each selected agent, `prepareBindings` durably, launch/wait for Codex process readiness, record the observed Codex session ID on that binding when available, submit bootstrap, then await coordinator state until that binding becomes ready or its `readyDeadline` passes. A timeout calls `removeAgent(agentID: expectedBindingID: cause:)` with the timed-out agent ID, its generated binding ID, and cause `"ready_timeout"`. Worker-count reduction unregisters extra bindings but never calls `closeWorkerSurface`.

- [ ] **Step 4: Add handshake tests**

Cover matching ready acceptance, wrong surface/role/agent rejection, stale binding rejection, ready timeout removal, no text reads, launch-wrapper offline command, and pane-close recorder remaining empty during manual/automatic removal.

- [ ] **Step 5: Run and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueHandshakePreparationTests -only-testing:cmuxTests/AgentQueuePreparationTests -only-testing:cmuxTests/AgentQueuePaneAdapterTests
rtk git add Sources/AgentQueue/AgentQueueCLIInstructionBuilder.swift Sources/AgentQueue/AgentQueuePaneAdapter.swift Sources/AgentQueue/AgentQueueWorkerPreparationService.swift Sources/AgentQueue/AgentQueuePreparationModels.swift cmuxTests/AgentQueueHandshakePreparationTests.swift cmuxTests/AgentQueuePreparationTests.swift cmuxTests/AgentQueuePaneAdapterTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "feat: require agent queue binding handshakes"
```

Expected: suites pass; `rtk rg -n 'readText|readTerminalTextRawSnapshot|visibleText' Sources/AgentQueue` returns no runtime matches.

---

### Task 7: Add the Agent Queue JSON-RPC Domain on the Socket Worker Lane

**Files:**
- Create: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/AgentQueue/ControlAgentQueueCall.swift`
- Create: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/AgentQueue/ControlAgentQueueContext.swift`
- Create: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/AgentQueue/ControlCommandCoordinator+AgentQueue.swift`
- Create: `Packages/macOS/CmuxControlSocket/Tests/CmuxControlSocketTests/ControlCommandCoordinatorAgentQueueTests.swift`
- Modify: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/ControlCommandContext.swift`
- Modify: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Coordinator/ControlCommandCoordinator.swift`
- Modify: `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlCommandExecutionPolicy.swift`
- Modify: `Packages/macOS/CmuxControlSocket/Tests/CmuxControlSocketTests/ControlCommandContextTestStubs.swift`
- Modify: `Packages/macOS/CmuxControlSocket/Tests/CmuxControlSocketTests/ControlCommandExecutionPolicyTests.swift`

**Interfaces:**
- Consumes: JSON-RPC `ControlRequest`/`JSONValue` and an app-provided async context.
- Produces: transport validation for all approved `agent_queue.*` methods without importing app-owned Agent Queue types.

- [ ] **Step 1: Define package DTO and context seam**

```swift
public struct ControlAgentQueueCall: Sendable, Equatable {
    public let method: String
    public let workspaceID: UUID
    public let surfaceID: UUID
    public let params: [String: JSONValue]
}

public protocol ControlAgentQueueContext: AnyObject, Sendable {
    nonisolated func controlAgentQueue(_ call: ControlAgentQueueCall) async -> ControlCallResult
}
```

Document both public symbols and initializers with DocC. Add `ControlAgentQueueContext` to the umbrella protocol.

- [ ] **Step 2: Parse all methods off-main**

`handleAgentQueue(_:context:) async -> ControlCallResult?` owns exactly:

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

Require UUID `workspace_id` and `surface_id` for every call and return `invalid_params` rather than resolving focused state. Validate required scalar/array/object shapes before calling context. Preserve task/report string values as decoded. Add the methods to `socketWorkerMethods`, never `mainThreadCallableSocketWorkerMethods`, and route them through a new async coordinator method from the worker response path.

- [ ] **Step 3: Add package behavior tests**

Use a recording context actor. Assert valid calls forward exact values, missing/malformed caller context rejects without context invocation, all methods classify worker-only, unknown method returns `nil`, and enqueue special characters from Task 1 remain byte-for-byte equal after JSON decoding.

- [ ] **Step 4: Run package tests and commit**

```bash
rtk swift test --package-path Packages/macOS/CmuxControlSocket --filter ControlCommandCoordinatorAgentQueueTests
rtk swift test --package-path Packages/macOS/CmuxControlSocket --filter ControlCommandExecutionPolicyTests
rtk git add Packages/macOS/CmuxControlSocket
rtk git commit -m "feat: add agent queue socket domain"
```

Expected: both filtered suites pass.

---

### Task 8: Bridge Socket Calls into App Coordinators Without Focus Mutation

**Files:**
- Create: `Sources/TerminalController+ControlAgentQueueContext.swift`
- Create: `Sources/AgentQueue/AgentQueueControlCallAdapter.swift`
- Create: `Sources/AgentQueue/AgentQueueRestoreCandidate.swift`
- Create: `cmuxTests/TerminalControllerAgentQueueSocketTests.swift`
- Create: `cmuxTests/AppDelegateAgentQueueRestoreTests.swift`
- Modify: `Sources/TerminalController.swift`
- Modify: `Sources/AgentQueue/AgentQueueController.swift`
- Modify: `Sources/RightSidebarPanelView.swift`
- Modify: `Sources/AppDelegate.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: package `ControlAgentQueueCall`, registry actor, and coordinator methods.
- Produces: one async app bridge, composition-root registry ownership, sidebar-independent startup restoration, and focus-preservation integration tests.

- [ ] **Step 1: Own registry/factory at the existing composition root**

Add a `nonisolated let agentQueueCoordinatorRegistry` to `TerminalController` and a main-actor `agentQueueControllerFactory` constructed with that registry. Remove `AgentQueueControllerFactory.shared`; `RightSidebarPanelView` requests controllers through `TerminalController.shared.agentQueueControllerFactory`. Controller startup awaits registry registration before enabling prepare actions.

Factory persistence identity is `workspace.stableId`, while socket routing remains `workspace.id`. Expose:

```swift
@MainActor
struct AgentQueueRestoreCandidate {
    let workspace: Workspace
    let tabManager: TabManager
    let persistenceID: UUID
    let legacyWorkspaceID: UUID?
}

@MainActor
func restorePersistedControllers(_ candidates: [AgentQueueRestoreCandidate]) async
```

The factory checks stable storage first and the legacy ID only for a candidate whose workspace adopted the snapshot's `stableId`. It creates/registers only controllers with persisted bytes, starts their reconciler without mounting the sidebar, and immediately reconciles restored surfaces. A factory call from `RightSidebarPanelView` reuses that same controller.

- [ ] **Step 2: Implement direct async routing**

```swift
extension TerminalController: ControlAgentQueueContext {
    nonisolated func controlAgentQueue(_ call: ControlAgentQueueCall) async -> ControlCallResult {
        guard let coordinator = await agentQueueCoordinatorRegistry.coordinator(
            workspaceID: call.workspaceID
        ) else {
            return .err(code: "agent_queue_unavailable", message: "Agent Queue is not initialized for this workspace.", data: nil)
        }
        return await AgentQueueControlCallAdapter.handle(call, coordinator: coordinator)
    }
}
```

`AgentQueueControlCallAdapter` is a value type in its own file that maps DTOs/results/errors. It never calls `controlResolveOnMain`, `v2MainSync`, workspace selection, or focus methods. `socketWorkerV2Response` uses the existing `v2AsyncResultCall` only for methods whose name begins with `agent_queue.`, awaits the package async handler, and renders its `ControlCallResult`.

- [ ] **Step 3: Restore persisted queues after session restoration**

In `AppDelegate`, collect restore candidates when each `SessionWindowSnapshot.tabManager` is applied by zipping its workspace snapshots with the resulting `TabManager.tabs`. Set `legacyWorkspaceID` only when `snapshotWorkspace.stableId == restoredWorkspace.stableId`; otherwise use `nil`. After the last startup/manual restore window finishes and before `completeSessionRestoreOperation` discards restore context, await `agentQueueControllerFactory.restorePersistedControllers(candidates)`. The restore call must not select a workspace, reveal the sidebar, or focus a surface. Clear the candidate buffer after the async restore starts from an immutable copy.

`AppDelegateAgentQueueRestoreTests` uses a hidden sidebar plus one stable-ID persisted queue and proves restore creates the coordinator/registry entry and runs reconciliation. Add a legacy-file case that migrates only when stable identity was adopted, rebases runtime workspace IDs, writes the stable-ID file before deleting the old file, and a duplicate/manual-reopen case that does not claim the old queue.

- [ ] **Step 4: Add integration tests**

Create a workspace with planner/worker bindings, record selected workspace, focused pane, and focused surface, then drive `ready`, `enqueue`, `report`, `remove`, `pause`, and `resume` through `handleSocketLine` on a non-main thread. Assert responses, coordinator state, and identical focus snapshots after each call. Also assert missing registry and wrong caller surface errors.

- [ ] **Step 5: Run, wire, and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk ./scripts/lint-pbxproj-test-wiring.sh
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/TerminalControllerAgentQueueSocketTests -only-testing:cmuxTests/AppDelegateAgentQueueRestoreTests
rtk git add Sources/TerminalController.swift Sources/TerminalController+ControlAgentQueueContext.swift Sources/AgentQueue/AgentQueueControlCallAdapter.swift Sources/AgentQueue/AgentQueueRestoreCandidate.swift Sources/AgentQueue/AgentQueueController.swift Sources/RightSidebarPanelView.swift Sources/AppDelegate.swift cmuxTests/TerminalControllerAgentQueueSocketTests.swift cmuxTests/AppDelegateAgentQueueRestoreTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "feat: bridge agent queue socket commands"
```

Expected: both suites pass; socket calls stay off-main/focus-neutral, and persisted queues restore with the sidebar hidden.

---

### Task 9: Add the Thin `cmux agent-queue` CLI and Actual Wire Regression

**Files:**
- Create: `CLI/CMUXCLI+AgentQueue.swift`
- Create: `cmuxTests/CMUXCLIAgentQueueRegressionTests.swift`
- Modify: `CLI/cmux.swift`
- Modify: `Resources/Localizable.xcstrings`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SocketClient.sendV2`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, stdin.
- Produces: documented `agent-queue` CLI, structured JSON stdout/stderr, exact UTF-8 wire mapping.

- [ ] **Step 1: Add red bundled-CLI tests against a fake Unix socket**

Create a serialized Swift Testing suite that launches the bundled CLI with a temporary fake socket and injected caller UUIDs. Test:

```swift
@Test func enqueuePreservesSpecialCharactersOnWire() throws
@Test func reportSendsPlainUTF8BodyAndBinding() throws
@Test func readyMapsAgentRoleAndBinding() throws
@Test func missingWorkspaceOrSurfaceFailsBeforeSocketConnection() throws
@Test func serverErrorUsesNonzeroExitAndJSONStderr() throws
@Test func helpListsEveryAgentQueueSubcommand() throws
```

For enqueue, write Task 1 JSON to stdin, decode the fake server's received line, and assert method `agent_queue.task.enqueue`, caller IDs, and exact title/body equality. Respond with a v2 success envelope and assert stdout parses as JSON. Commit these tests before CLI production changes.

- [ ] **Step 2: Wire and prove RED, then commit test-only**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk ./scripts/lint-pbxproj-test-wiring.sh
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/CMUXCLIAgentQueueRegressionTests
rtk git add cmuxTests/CMUXCLIAgentQueueRegressionTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "test: specify agent queue CLI wire protocol"
```

Expected: test executable reports unknown `agent-queue` command.

- [ ] **Step 3: Implement CLI parser and stdin rules**

Add:

```swift
extension CMUXCLI {
    func runAgentQueueCommand(
        commandArgs: [String],
        client: SocketClient,
        environment: [String: String]
    ) throws
}
```

Supported syntax:

```text
cmux agent-queue enqueue --stdin
cmux agent-queue report --task ID --report ID --status completed|failed|blocked --binding ID --stdin
cmux agent-queue agent ready --agent ID --role planner|worker --binding ID
cmux agent-queue agent offline --agent ID --binding ID
cmux agent-queue agent list
cmux agent-queue agent remove --agent ID [--binding ID]
cmux agent-queue agent reconcile
cmux agent-queue task list
cmux agent-queue pause
cmux agent-queue resume
```

Require UUID environment values with no focused fallback. `enqueue --stdin` requires nonempty UTF-8 JSON object and sends it as `submission`; report stdin is optional plain UTF-8 and defaults to `""`. Reject unknown/repeated/missing flags before socket I/O. Print success using JSON serialization with sorted keys.

- [ ] **Step 4: Add structured CLI errors and localized help**

Extend `CLIError` with optional `structuredPayload: [String: Any]?`. Main writes that payload directly to stderr when present; Agent Queue parser/server errors use `{"ok":false,"error":{"code":"invalid_params","message":"agent-queue requires CMUX_WORKSPACE_ID and CMUX_SURFACE_ID"}}` for validation and the same object shape with code `transport_error` or the server error code for runtime failures. Exit 2 for usage/validation and 1 for transport/server failure. Add `cli.agentQueue.usage`, `cli.agentQueue.error.contextRequired`, `cli.agentQueue.error.invalidUTF8`, `cli.agentQueue.error.invalidJSON`, `cli.agentQueue.error.missingOption`, `cli.agentQueue.error.invalidStatus`, and `cli.agentQueue.error.unknownSubcommand` to English/Japanese catalog entries. Add `agent-queue` to global usage and `subcommandUsage`.

- [ ] **Step 5: Wire CLI source, verify GREEN, and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk ./scripts/check-cli-stdio-safety.sh CLI
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/CMUXCLIAgentQueueRegressionTests
rtk git add CLI/CMUXCLI+AgentQueue.swift CLI/cmux.swift cmux.xcodeproj/project.pbxproj
rtk git add -p Resources/Localizable.xcstrings
rtk git commit -m "feat: add agent queue CLI"
```

Expected: wire suite passes; stdio audit passes.

---

### Task 10: Reconcile Surface and Process Lifecycle Events

**Files:**
- Create: `Sources/AgentQueue/AgentQueueTopologyReconciler.swift`
- Create: `Sources/CmuxSurfaceClosedEvent.swift`
- Create: `cmuxTests/AgentQueueTopologyReconcilerTests.swift`
- Modify: `Sources/CmuxEventBus.swift`
- Modify: `Sources/CmuxEventPublishing.swift`
- Modify: `Sources/Mobile/AgentChat/AgentChatTranscriptService.swift`
- Modify: `Sources/AgentQueue/AgentQueueController.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: typed `surface.closed`, agent transcript state changes, workspace surface snapshots, app activation, and coordinator removal/reconcile.
- Produces: immediate close/process handling plus restore/app-active/10-second safety repair without terminal reads.

- [ ] **Step 1: Add typed async lifecycle streams**

```swift
struct CmuxSurfaceClosedEvent: Sendable, Equatable {
    let workspaceID: UUID
    let surfaceID: UUID
    let paneID: UUID?
    let origin: String
}
```

Expose `CmuxEventBus.surfaceClosedEvents() -> AsyncStream<CmuxSurfaceClosedEvent>` using continuations stored under the bus's existing lock; `publishSurfaceClosed` yields after publishing the public `surface.closed` envelope. Add `AgentChatTranscriptService.lifecycleEvents() -> AsyncStream<AgentChatSessionRecord>` under its existing `@MainActor` isolation and yield only meaningful state transitions.

- [ ] **Step 2: Implement reconciler with injected inventory and clock**

```swift
@MainActor
final class AgentQueueTopologyReconciler {
    init(
        workspaceID: UUID,
        coordinator: AgentQueueCoordinator,
        liveSurfaceIDs: @escaping @MainActor () -> Set<UUID>,
        endedBindingIDs: @escaping @MainActor () -> Set<String>,
        clock: ContinuousClock = .init()
    )
    func start(surfaceEvents: AsyncStream<CmuxSurfaceClosedEvent>, processEvents: AsyncStream<AgentChatSessionRecord>)
    func reconcile(cause: String)
    func stop()
}
```

Surface event calls shared `removeAgent` for matching bindings. Ended Codex event does the same with cause `process_ended` only when its session ID equals the current binding's `observedSessionID`; this prevents an old ended record on a reused surface from removing a replacement generation. `reconcile` sends live surface IDs and ended current-binding IDs to coordinator. Run reconcile after preparation, restore, `NSApplication.didBecomeActiveNotification`, and every 10 seconds. The periodic `clock.sleep(for:)` has a one-line comment stating it is an injected, cancellable safety deadline rather than condition polling; store/cancel all Tasks.

- [ ] **Step 3: Test the full policy table**

Cover idle Worker close continues, active Worker close blocks/pauses, Planner close clears/pauses, active manual removal equals close transition and leaves fake close/terminate counters zero, ended process follows offline path, stale close cannot remove replacement binding, missed close repaired by reconcile, app-active triggers reconcile, and safety tick does not read terminal text.

- [ ] **Step 4: Wire, run, and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueTopologyReconcilerTests
rtk git add Sources/AgentQueue/AgentQueueTopologyReconciler.swift Sources/CmuxSurfaceClosedEvent.swift Sources/CmuxEventBus.swift Sources/CmuxEventPublishing.swift Sources/Mobile/AgentChat/AgentChatTranscriptService.swift Sources/AgentQueue/AgentQueueController.swift cmuxTests/AgentQueueTopologyReconcilerTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "feat: reconcile agent queue lifecycle"
```

Expected: lifecycle suite passes and fake pane/process termination counts stay zero.

---

### Task 11: Teach Planner and Worker Skills the CLI-Only Contract

**Files:**
- Modify: `skills/cmux-agent-queue-planner/SKILL.md`
- Modify: `skills/cmux-agent-queue-worker/SKILL.md`
- Create: `cmuxTests/AgentQueueCLIInstructionBuilderTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: CLI syntax and builder from Tasks 6/9.
- Produces: agents that enqueue/report with stable IDs and never rely on pane output detection.

- [ ] **Step 1: Update Planner workflow**

Require Planner to generate stable `submission_id`, write one JSON object to stdin, call `cmux agent-queue enqueue --stdin`, preserve exact task content, retry the same ID/payload after uncertain transport, and use a new ID after changing payload. Explicitly forbid marker output, `cmux send`, pane focus, and task implementation.

- [ ] **Step 2: Update Worker completion workflow**

Require one stable `report_id` per report attempt and:

```bash
printf '%s' "$report_body" | cmux agent-queue report \
  --task "$AGENT_QUEUE_TASK_ID" \
  --report "$report_id" \
  --status completed \
  --binding "$AGENT_QUEUE_BINDING_ID" \
  --stdin
```

Use `failed` for recoverable execution failure and `blocked` when user/safety input is required. Explicitly say terminal prose does not complete tasks; retry uncertain transport with the same report ID/body/status.

- [ ] **Step 3: Test generated prompts behaviorally**

Assert bootstrap puts ready first, task prompt exports exact `AGENT_QUEUE_TASK_ID`/`AGENT_QUEUE_BINDING_ID`, completion instructions contain report CLI and stable report ID guidance, recovery prompt keeps the same binding, and no prompt contains `[AGENT_QUEUE_TASKS]`, `[AGENT_QUEUE_REPORT]`, screen polling, or `cmux send`.

- [ ] **Step 4: Run and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueCLIInstructionBuilderTests
rtk git add skills/cmux-agent-queue-planner/SKILL.md skills/cmux-agent-queue-worker/SKILL.md cmuxTests/AgentQueueCLIInstructionBuilderTests.swift cmux.xcodeproj/project.pbxproj
rtk git commit -m "docs: move agent queue roles to CLI protocol"
```

Expected: instruction suite passes.

---

### Task 12: Remove Goal/Start UI and Add Pause, Resume, and Registration Removal

**Files:**
- Modify: `Sources/AgentQueue/AgentQueueSidebarView.swift`
- Modify: `Sources/AgentQueue/AgentQueueAgentProfileView.swift`
- Modify: `Resources/Localizable.xcstrings`
- Create: `cmuxTests/AgentQueueSidebarProjectionTests.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Observation façade state/actions.
- Produces: immediate-operation sidebar with readiness/status, sticky pause controls, and unregister-only actions.

- [ ] **Step 1: Project immutable row values**

Define value snapshots above the collection boundary:

```swift
struct AgentQueueAgentRowSnapshot: Identifiable, Equatable {
    let id: String
    let role: AgentQueueAgentRole
    let readiness: AgentQueueAgentReadiness
    let surfaceLabel: String?
    let taskTitle: String?
    let canRemoveRegistration: Bool
}

struct AgentQueueAgentRowActions {
    let removeRegistration: () -> Void
    let reprepare: () -> Void
}
```

Rows store only these values/closures. Root view uses `@Bindable var controller`; no row stores controller/coordinator.

- [ ] **Step 2: Replace UI controls**

Delete `taskInput`, `inputSection`, Planner waiting/error UI, `canRequestPlan`, and Start button. Header shows Pause when running and Resume when paused. Planner/Worker rows show readiness/binding/surface/current task and a Remove Registration action; Planner removal remains available but clears registration rather than deleting the row. Re-prepare is explicit and never resumes a paused queue.

- [ ] **Step 3: Add projection/action tests**

Test Goal/Start projection absence through the view-model seam, Pause/Resume action routing, Planner/Worker removal routing, active Worker remove result, and immutable row snapshots updating only after committed state stream values.

- [ ] **Step 4: Localize and audit**

Add English/Japanese values for these exact keys:

```text
agentQueue.resume: Resume / 再開
agentQueue.removeRegistration: Remove Registration / 登録を解除
agentQueue.reprepare: Re-prepare / 再準備
agentQueue.agent.pending: Waiting for handshake / ハンドシェイク待機中
agentQueue.agent.notReady: Not ready / 未準備
agentQueue.lifecycle.activeWorkerLost: Active Worker was lost; its task was blocked. / 実行中の Worker が失われたため、タスクをブロックしました。
agentQueue.lifecycle.plannerLost: Planner registration was lost; queue paused. / Planner の登録が失われたため、キューを一時停止しました。
```

Run:

```bash
rtk python3 -m json.tool Resources/Localizable.xcstrings
rtk rg -n 'agentQueue\.(resume|removeRegistration|reprepare|agent\.(pending|notReady)|lifecycle\.)' Resources/Localizable.xcstrings
rtk rg -n 'Text\("[A-Za-z]|Button\("[A-Za-z]|Label\("[A-Za-z]' Sources/AgentQueue/AgentQueueSidebarView.swift Sources/AgentQueue/AgentQueueAgentProfileView.swift
```

Expected: JSON parses; each new key has `en` and `ja`; bare-English scan shows no new user-facing literals.

- [ ] **Step 5: Run and commit**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueSidebarProjectionTests
rtk git add Sources/AgentQueue/AgentQueueSidebarView.swift Sources/AgentQueue/AgentQueueAgentProfileView.swift cmuxTests/AgentQueueSidebarProjectionTests.swift cmux.xcodeproj/project.pbxproj
rtk git add -p Resources/Localizable.xcstrings
rtk git commit -m "feat: show immediate agent queue lifecycle controls"
```

Expected: projection suite passes.

---

### Task 13: Delete Legacy Screen Protocol Runtime and Finish Migration

**Files:**
- Delete: `Sources/AgentQueue/AgentQueuePlanDetector.swift`
- Delete: `Sources/AgentQueue/AgentQueueReportDetector.swift`
- Delete: `Sources/AgentQueue/AgentQueuePlanningRequest.swift`
- Delete: `Sources/AgentQueue/AgentQueuePlannedTask.swift`
- Delete: `Sources/AgentQueue/AgentQueuePlannedTasks.swift`
- Delete: `Sources/AgentQueue/AgentQueuePlanDetectionError.swift`
- Delete: `cmuxTests/AgentQueuePlanDetectorTests.swift`
- Delete: `cmuxTests/AgentQueueReportDetectorTests.swift`
- Modify: `Sources/AgentQueue/AgentQueueController.swift`
- Modify: `Sources/AgentQueue/AgentQueueStore.swift`
- Modify carefully: `Sources/AgentQueue/AgentQueueInstructionBuilder.swift` only to preserve its existing unstaged change while removing remaining production references
- Modify carefully: `cmuxTests/AgentQueueControllerTests.swift` and `cmuxTests/AgentQueueInstructionBuilderTests.swift` only to preserve existing unstaged changes while deleting obsolete screen-protocol expectations
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: complete CLI runtime and migration.
- Produces: zero production plan/report screen reads and no dead detector target wiring.

- [ ] **Step 1: Prove no production callers remain**

```bash
rtk rg -n 'AgentQueuePlanDetector|AgentQueueReportDetector|AgentQueuePlanningRequest|plannerJSONCorrectionRequest|pollReportsOnce|readText\(' Sources
```

Expected before deletion: definitions/dead references only; no controller/preparation runtime caller. If a caller remains, route it through coordinator/CLI before deleting.

- [ ] **Step 2: Delete detector/runtime files and pbx entries**

Remove production/test file references, build files, group children, and Sources-phase entries. Remove the legacy `AgentQueueStore` adapter after all callers use coordinator persistence. Keep legacy enum decode cases only in migration types; the v2 reducer never emits them.

- [ ] **Step 3: Normalize and run the complete Agent Queue test set**

```bash
rtk python3 scripts/normalize-pbxproj.py cmux.xcodeproj/project.pbxproj
rtk ./scripts/check-pbxproj.sh
rtk ./scripts/lint-pbxproj-test-wiring.sh
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueStateMigrationTests -only-testing:cmuxTests/AgentQueuePayloadRoundTripTests -only-testing:cmuxTests/AgentQueueCoreTests -only-testing:cmuxTests/AgentQueueCoordinatorTests -only-testing:cmuxTests/AgentQueueEffectExecutorTests -only-testing:cmuxTests/AgentQueueControllerTests -only-testing:cmuxTests/AgentQueueHandshakePreparationTests -only-testing:cmuxTests/AgentQueuePreparationTests -only-testing:cmuxTests/AgentQueuePaneAdapterTests -only-testing:cmuxTests/AgentQueueTopologyReconcilerTests -only-testing:cmuxTests/AgentQueueCLIInstructionBuilderTests -only-testing:cmuxTests/AgentQueueSidebarProjectionTests -only-testing:cmuxTests/TerminalControllerAgentQueueSocketTests -only-testing:cmuxTests/CMUXCLIAgentQueueRegressionTests
```

Expected: every listed suite executes at least one test and all pass.

- [ ] **Step 4: Confirm terminal protocol removal and commit**

```bash
rtk rg -n 'AgentQueuePlanDetector|AgentQueueReportDetector|pollReportsOnce|readTerminalTextRawSnapshot|plannerJSONCorrectionRequest' Sources/AgentQueue
rtk git status --short
rtk git add Sources/AgentQueue/AgentQueuePlanDetector.swift Sources/AgentQueue/AgentQueueReportDetector.swift Sources/AgentQueue/AgentQueuePlanningRequest.swift Sources/AgentQueue/AgentQueuePlannedTask.swift Sources/AgentQueue/AgentQueuePlannedTasks.swift Sources/AgentQueue/AgentQueuePlanDetectionError.swift Sources/AgentQueue/AgentQueueController.swift Sources/AgentQueue/AgentQueueStore.swift cmuxTests/AgentQueuePlanDetectorTests.swift cmuxTests/AgentQueueReportDetectorTests.swift cmux.xcodeproj/project.pbxproj
rtk git add -p Sources/AgentQueue/AgentQueueInstructionBuilder.swift cmuxTests/AgentQueueControllerTests.swift cmuxTests/AgentQueueInstructionBuilderTests.swift
rtk git commit -m "refactor: remove agent queue screen protocols"
```

Expected: first command returns no matches. `.serena/` remains untracked and unstaged.

---

### Task 14: Full Verification, Localization Audit, and Tagged Build

**Files:**
- Verify all changed files; change code only after reproducing a failure with a behavioral test.

**Interfaces:**
- Consumes: complete implementation.
- Produces: build/test/localization/focus evidence and dogfood-ready tagged app.

- [ ] **Step 1: Run integrity and placeholder scans**

```bash
rtk git diff --check origin/main...HEAD
rtk ./scripts/check-pbxproj.sh
rtk ./scripts/lint-pbxproj-test-wiring.sh
rtk ./scripts/check-cli-stdio-safety.sh CLI
rtk python3 scripts/check-package-resolved-policy.py
rtk python3 scripts/check-workspace-package-groups.py --check
rtk python3 -m json.tool Resources/Localizable.xcstrings
```

Expected: all pass.

- [ ] **Step 2: Run package and focused app tests**

```bash
rtk swift test --package-path Packages/macOS/CmuxControlSocket
rtk xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-agent-queue-planner-ingest-tests -only-testing:cmuxTests/AgentQueueStateMigrationTests -only-testing:cmuxTests/AgentQueuePayloadRoundTripTests -only-testing:cmuxTests/AgentQueueCoreTests -only-testing:cmuxTests/AgentQueueCoordinatorTests -only-testing:cmuxTests/AgentQueueEffectExecutorTests -only-testing:cmuxTests/AgentQueueControllerTests -only-testing:cmuxTests/AgentQueueHandshakePreparationTests -only-testing:cmuxTests/AgentQueuePreparationTests -only-testing:cmuxTests/AgentQueuePaneAdapterTests -only-testing:cmuxTests/AgentQueueTopologyReconcilerTests -only-testing:cmuxTests/AgentQueueCLIInstructionBuilderTests -only-testing:cmuxTests/AgentQueueSidebarProjectionTests -only-testing:cmuxTests/TerminalControllerAgentQueueSocketTests -only-testing:cmuxTests/CMUXCLIAgentQueueRegressionTests
```

Expected: all package/app tests pass with nonzero executed counts.

- [ ] **Step 3: Perform localization audit**

Enumerate changed user-facing surfaces: Agent Queue sidebar, lifecycle errors, CLI help, CLI validation errors, Planner bootstrap text, Worker report text. Compare new keys' English/Japanese locale sets and scan changed Swift/Markdown:

```bash
rtk git diff --name-only origin/main...HEAD | rtk rg '\.(swift|md)$'
rtk rg -n 'String\(localized: "(agentQueue|cli\.agentQueue)\.' Sources CLI
rtk rg -n 'Text\("[A-Za-z]|Button\("[A-Za-z]|Label\("[A-Za-z]' Sources/AgentQueue
```

Expected: every new user-facing literal is catalog-backed; keys have both `en` and `ja`.

- [ ] **Step 4: Build the required tagged app**

```bash
rtk ./scripts/reload.sh --tag agent-queue-planner-ingest
```

Expected: build succeeds and output contains an `App path:` under `~/Library/Developer/Xcode/DerivedData/cmux-agent-queue-planner-ingest/...`, not `/tmp`.

- [ ] **Step 5: Dogfood exact acceptance paths without focus changes**

Using the tagged CLI helper only:

```bash
rtk proxy env CMUX_TAG=agent-queue-planner-ingest scripts/cmux-debug-cli.sh agent-queue task list
```

Then prepare Planner plus two Workers in one isolated workspace and verify: ready handshakes arrive; special-character enqueue round-trips; exactly two tasks dispatch immediately; a third stays queued; completion schedules the third; pause stays paused across enqueue/reprepare; idle Worker close continues; active Worker close blocks/pauses; Planner close pauses/notReady; manual removal leaves its pane open; no action changes focused workspace/pane/surface.

- [ ] **Step 6: Review final history and working tree**

```bash
rtk git status --short
rtk git diff --stat origin/main...HEAD
rtk git log --oneline origin/main..HEAD
```

Expected: only intended files/commits; existing local edits remain preserved; `.serena/` is not staged.
