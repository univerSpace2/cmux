import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct AgentQueueEffectExecutorTests {
    @Test func successfulPromptSubmissionRecordsDispatch() async throws {
        let fixture = try EffectExecutorFixture.make()
        let coordinator = fixture.coordinator()
        let pane = RecordingEffectPaneAdapter()
        let executor = AgentQueueEffectExecutor(coordinator: coordinator, paneAdapter: pane)
        let updates = await coordinator.stateUpdates()
        var iterator = updates.makeAsyncIterator()
        executor.start()
        await Task.yield()

        let enqueue = try await coordinator.enqueue(
            fixture.enqueueRequest,
            caller: fixture.plannerCaller
        )
        var dispatched: AgentQueueState?
        while let update = await iterator.next() {
            if update.tasks.first?.status == .dispatched {
                dispatched = update
                break
            }
        }
        executor.stop()

        #expect(dispatched?.tasks.first?.id == enqueue.taskIDs[0])
        #expect(dispatched?.workers.first?.status == .running)
        #expect(pane.submittedTexts.count == 1)
        #expect(pane.submittedTexts[0].contains(enqueue.taskIDs[0]))
        #expect(pane.submittedTexts[0].contains("binding-worker-1"))
    }

    @Test func submissionFailureBlocksTaskAndPauses() async throws {
        var fixture = try EffectExecutorFixture.make(taskCount: 1)
        fixture.markFirstTaskDispatching()
        let coordinator = fixture.coordinator()
        let pane = RecordingEffectPaneAdapter(failure: .injected)
        let executor = AgentQueueEffectExecutor(coordinator: coordinator, paneAdapter: pane)

        await executor.execute(
            .dispatch(
                taskID: "T-20260714-0001",
                workerID: "worker-1",
                bindingID: "binding-worker-1"
            )
        )
        let snapshot = await coordinator.snapshot()

        #expect(snapshot.tasks[0].status == .blocked)
        #expect(snapshot.queue.status == .paused)
        #expect(snapshot.workers.isEmpty)
    }

    @Test func staleEffectIsIgnoredAfterBindingReplacement() async throws {
        var fixture = try EffectExecutorFixture.make(taskCount: 1)
        fixture.markFirstTaskDispatching()
        let coordinator = fixture.coordinator()
        let pane = RecordingEffectPaneAdapter()
        let executor = AgentQueueEffectExecutor(coordinator: coordinator, paneAdapter: pane)
        var replacement = fixture.workerBinding
        replacement.bindingID = "binding-worker-2"
        replacement.readiness = .pending
        try await coordinator.prepareBindings([replacement])
        let revision = await coordinator.snapshot().revision

        await executor.execute(
            .dispatch(
                taskID: "T-20260714-0001",
                workerID: "worker-1",
                bindingID: "binding-worker-1"
            )
        )

        #expect(pane.submittedTexts.isEmpty)
        #expect(await coordinator.snapshot().revision == revision)
    }

    @Test func recoveryPromptTargetsSameWorkerBinding() async throws {
        var fixture = try EffectExecutorFixture.make(taskCount: 1)
        fixture.markFirstTaskRecovering()
        let coordinator = fixture.coordinator()
        let pane = RecordingEffectPaneAdapter()
        let executor = AgentQueueEffectExecutor(coordinator: coordinator, paneAdapter: pane)

        await executor.execute(
            .recover(
                taskID: "T-20260714-0001",
                workerID: "worker-1",
                bindingID: "binding-worker-1"
            )
        )
        let snapshot = await coordinator.snapshot()

        #expect(pane.submittedSurfaceIDs == [fixture.workerSurfaceID])
        #expect(pane.submittedTexts[0].contains("binding-worker-1"))
        #expect(snapshot.tasks[0].status == .dispatched)
        #expect(snapshot.workers[0].status == .running)
    }

    @Test func registryReturnsRegisteredCoordinator() async throws {
        let fixture = try EffectExecutorFixture.make()
        let coordinator = fixture.coordinator()
        let registry = AgentQueueCoordinatorRegistry()

        await registry.register(coordinator, workspaceID: fixture.workspaceID)
        let found = await registry.coordinator(workspaceID: fixture.workspaceID)
        #expect(found === coordinator)
        #expect(await registry.allCoordinators().count == 1)
        await registry.unregister(workspaceID: fixture.workspaceID)
        #expect(await registry.coordinator(workspaceID: fixture.workspaceID) == nil)
    }
}

private struct EffectExecutorFixture {
    let workspaceID: UUID
    let persistenceID: UUID
    let plannerSurfaceID: UUID
    let workerSurfaceID: UUID
    let workerBinding: AgentQueueAgentBinding
    let rootDirectory: URL
    var state: AgentQueueState

    var plannerCaller: AgentQueueCallerContext {
        .init(workspaceID: workspaceID, surfaceID: plannerSurfaceID)
    }

    var enqueueRequest: AgentQueueEnqueueRequest {
        AgentQueueEnqueueRequest(
            submissionID: "submission-effect-1",
            tasks: [
                AgentQueueTaskDraft(
                    title: "Execute effect",
                    body: "Preserve \\ \"quotes\" 작업",
                    executionMode: .parallelAllowed,
                    timeoutSeconds: 1_800,
                    retryLimit: 1
                ),
            ]
        )
    }

    static func make(taskCount: Int = 0) throws -> EffectExecutorFixture {
        let now = Date(timeIntervalSince1970: 1_784_006_400)
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let plannerSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workerSurfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let workerBinding = AgentQueueAgentBinding(
            bindingID: "binding-worker-1",
            agentID: "worker-1",
            role: .worker,
            workspaceID: workspaceID,
            paneID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            surfaceID: workerSurfaceID,
            readiness: .ready,
            preparedAt: now,
            readyDeadline: now.addingTimeInterval(30),
            readyAt: now,
            lastSeenAt: now,
            observedSessionID: "session-worker-1"
        )
        let plannerBinding = AgentQueueAgentBinding(
            bindingID: "binding-planner-1",
            agentID: AgentQueueAgentID.planner,
            role: .planner,
            workspaceID: workspaceID,
            paneID: nil,
            surfaceID: plannerSurfaceID,
            readiness: .ready,
            preparedAt: now,
            readyDeadline: now.addingTimeInterval(30),
            readyAt: now,
            lastSeenAt: now,
            observedSessionID: "session-planner-1"
        )
        let queue = AgentQueue(
            id: "queue-1",
            workspaceID: workspaceID,
            plannerSurfaceID: plannerSurfaceID,
            status: .running,
            createdAt: now,
            updatedAt: now
        )
        let tasks = (0..<taskCount).map { offset in
            AgentTask(
                id: String(format: "T-20260714-%04d", offset + 1),
                queueID: queue.id,
                title: "Task \(offset + 1)",
                body: "Body \(offset + 1)",
                status: .queued,
                executionMode: .parallelAllowed,
                assignedWorkerSurfaceID: nil,
                dispatchAttemptCount: 0,
                recoveryAttemptCount: 0,
                timeoutSeconds: 1_800,
                retryLimit: 1,
                createdAt: now,
                dispatchedAt: nil,
                completedAt: nil,
                lastError: nil
            )
        }
        let worker = AgentWorker(
            id: "worker-1",
            workspaceID: workspaceID,
            paneID: workerBinding.paneID!,
            surfaceID: workerSurfaceID,
            label: "Worker 1",
            enabled: true,
            status: .idle,
            currentTaskID: nil,
            lastSeenAt: now,
            bindingID: workerBinding.bindingID
        )
        let preparation = AgentQueuePreparationState(
            configuration: .defaultConfiguration,
            phase: .ready,
            completedWorkerCount: 1,
            errorMessage: nil
        )
        return EffectExecutorFixture(
            workspaceID: workspaceID,
            persistenceID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            plannerSurfaceID: plannerSurfaceID,
            workerSurfaceID: workerSurfaceID,
            workerBinding: workerBinding,
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-queue-effects-\(UUID().uuidString)", isDirectory: true),
            state: AgentQueueState(
                queue: queue,
                tasks: tasks,
                workers: [worker],
                bindings: [plannerBinding, workerBinding],
                events: [],
                preparation: preparation
            )
        )
    }

    func coordinator() -> AgentQueueCoordinator {
        AgentQueueCoordinator(
            workspaceID: workspaceID,
            persistenceID: persistenceID,
            legacyWorkspaceID: nil,
            initialState: state,
            persistence: AgentQueueFilePersistence(rootDirectory: rootDirectory),
            now: { Date(timeIntervalSince1970: 1_784_006_400) }
        )
    }

    mutating func markFirstTaskDispatching() {
        state.tasks[0].status = .dispatching
        state.workers[0].status = .assigned
        state.workers[0].currentTaskID = state.tasks[0].id
    }

    mutating func markFirstTaskRecovering() {
        state.tasks[0].status = .retrying
        state.tasks[0].assignedWorkerSurfaceID = workerSurfaceID
        state.tasks[0].recoveryAttemptCount = 1
        state.workers[0].status = .recovering
        state.workers[0].currentTaskID = state.tasks[0].id
    }
}

private enum RecordingEffectPaneError: Error {
    case injected
}

@MainActor
private final class RecordingEffectPaneAdapter: AgentQueuePaneAdapting {
    let failure: RecordingEffectPaneError?
    private(set) var submittedTexts: [String] = []
    private(set) var submittedSurfaceIDs: [UUID] = []

    init(failure: RecordingEffectPaneError? = nil) {
        self.failure = failure
    }

    func submitText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        submittedTexts.append(text)
        submittedSurfaceIDs.append(surfaceID)
        if let failure { throw failure }
        return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }

    func submitShellCommand(_ command: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        try await submitText(command, to: surfaceID)
    }

    func readText(surfaceID: UUID, lines: Int) async throws -> AgentQueueSurfaceTextSnapshot {
        AgentQueueSurfaceTextSnapshot(surfaceID: surfaceID, text: "", capturedAt: Date())
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        .idle
    }
}
