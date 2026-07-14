import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct AgentQueueCoordinatorTests {
    @Test func identicalSubmissionReturnsOriginalTaskIDsWithoutSavingAgain() async throws {
        let fixture = try CoordinatorFixture.make()
        let coordinator = fixture.coordinator()
        let request = fixture.enqueueRequest(submissionID: "submission-1")

        let first = try await coordinator.enqueue(request, caller: fixture.plannerCaller)
        let second = try await coordinator.enqueue(request, caller: fixture.plannerCaller)

        #expect(first.taskIDs == second.taskIDs)
        #expect(first.idempotent == false)
        #expect(second.idempotent)
        #expect(try fixture.persistence.savedStates().count == 1)
    }

    @Test func conflictingSubmissionIDThrowsConflictWithoutMutation() async throws {
        let fixture = try CoordinatorFixture.make()
        let coordinator = fixture.coordinator()
        let original = fixture.enqueueRequest(submissionID: "submission-conflict")
        _ = try await coordinator.enqueue(original, caller: fixture.plannerCaller)
        var conflict = original
        conflict.tasks[0].body = "changed"

        await expectCoordinatorError(.conflict) {
            _ = try await coordinator.enqueue(conflict, caller: fixture.plannerCaller)
        }

        #expect(await coordinator.snapshot().revision == 1)
        #expect(try fixture.persistence.savedStates().count == 1)
    }

    @Test func invalidTaskRejectsWholeBatch() async throws {
        let fixture = try CoordinatorFixture.make()
        let coordinator = fixture.coordinator()
        var request = fixture.enqueueRequest(submissionID: "submission-invalid")
        request.tasks.append(
            AgentQueueTaskDraft(
                title: "   ",
                body: "invalid",
                executionMode: .parallelAllowed,
                timeoutSeconds: 30,
                retryLimit: 0
            )
        )

        await expectCoordinatorError(.invalidRequest) {
            _ = try await coordinator.enqueue(request, caller: fixture.plannerCaller)
        }

        #expect(await coordinator.snapshot().tasks.isEmpty)
        #expect(try fixture.persistence.savedStates().isEmpty)
    }

    @Test func onlyCurrentReadyPlannerSurfaceCanEnqueue() async throws {
        let fixture = try CoordinatorFixture.make()
        let coordinator = fixture.coordinator()
        let wrongCaller = AgentQueueCallerContext(
            workspaceID: fixture.workspaceID,
            surfaceID: fixture.workerSurfaceID
        )

        await expectCoordinatorError(.unauthorized) {
            _ = try await coordinator.enqueue(
                fixture.enqueueRequest(submissionID: "submission-wrong-caller"),
                caller: wrongCaller
            )
        }
        let accepted = try await coordinator.enqueue(
            fixture.enqueueRequest(submissionID: "submission-right-caller"),
            caller: fixture.plannerCaller
        )

        #expect(accepted.taskIDs.count == 1)
    }

    @Test func duplicateFailedReportDoesNotConsumeAnotherRetry() async throws {
        var fixture = try CoordinatorFixture.make(taskCount: 1)
        fixture.assignFirstTask()
        let coordinator = fixture.coordinator()
        let request = AgentQueueReportRequest(
            taskID: "T-20260714-0001",
            reportID: "report-failed-1",
            status: .failed,
            bindingID: "binding-worker-1",
            body: "retry me"
        )

        let first = try await coordinator.report(request, caller: fixture.workerCaller)
        let second = try await coordinator.report(request, caller: fixture.workerCaller)
        let snapshot = await coordinator.snapshot()

        #expect(first.idempotent == false)
        #expect(second.idempotent)
        #expect(snapshot.tasks[0].recoveryAttemptCount == 1)
        #expect(snapshot.reports.count == 1)
        #expect(try fixture.persistence.savedStates().count == 1)
    }

    @Test func staleBindingReadyOfflineAndReportCannotMutateReplacement() async throws {
        var fixture = try CoordinatorFixture.make(taskCount: 1)
        fixture.assignFirstTask()
        let coordinator = fixture.coordinator()
        var replacement = fixture.workerBinding
        replacement.bindingID = "binding-worker-2"
        replacement.readiness = .pending
        replacement.readyAt = nil
        try await coordinator.prepareBindings([replacement])
        let revision = await coordinator.snapshot().revision

        await expectCoordinatorError(.staleBinding) {
            _ = try await coordinator.markReady(
                agentID: "worker-1",
                role: .worker,
                bindingID: "binding-worker-1",
                caller: fixture.workerCaller
            )
        }
        await expectCoordinatorError(.staleBinding) {
            try await coordinator.markOffline(
                agentID: "worker-1",
                bindingID: "binding-worker-1",
                caller: fixture.workerCaller,
                cause: "stale"
            )
        }
        await expectCoordinatorError(.staleBinding) {
            _ = try await coordinator.report(
                AgentQueueReportRequest(
                    taskID: "T-20260714-0001",
                    reportID: "report-stale",
                    status: .completed,
                    bindingID: "binding-worker-1",
                    body: "stale"
                ),
                caller: fixture.workerCaller
            )
        }

        #expect(await coordinator.snapshot().revision == revision)
    }

    @Test func persistenceFailurePublishesNoStateAndYieldsNoEffects() async throws {
        let fixture = try CoordinatorFixture.make()
        let coordinator = fixture.coordinator()
        let stateProbe = StreamProbe<AgentQueueState>()
        let effectProbe = StreamProbe<AgentQueueSideEffect>()
        let stateStream = await coordinator.stateUpdates()
        let effectStream = await coordinator.effects()
        let stateTask = Task {
            for await value in stateStream { await stateProbe.append(value) }
        }
        let effectTask = Task {
            for await value in effectStream { await effectProbe.append(value) }
        }
        try fixture.persistence.setFailureEnabled(true)

        do {
            _ = try await coordinator.enqueue(
                fixture.enqueueRequest(submissionID: "submission-save-failure"),
                caller: fixture.plannerCaller
            )
            Issue.record("Expected persistence failure")
        } catch is RecordingPersistenceError {
            // Expected.
        }
        await Task.yield()
        await Task.yield()
        stateTask.cancel()
        effectTask.cancel()

        #expect(await coordinator.snapshot().revision == 0)
        #expect(await stateProbe.values().isEmpty)
        #expect(await effectProbe.values().isEmpty)
    }

    @Test func committedStateIsObservedBeforeDispatchEffect() async throws {
        let fixture = try CoordinatorFixture.make()
        let coordinator = fixture.coordinator()
        let stateStream = await coordinator.stateUpdates()
        let effectStream = await coordinator.effects()
        var stateIterator = stateStream.makeAsyncIterator()
        var effectIterator = effectStream.makeAsyncIterator()

        let result = try await coordinator.enqueue(
            fixture.enqueueRequest(submissionID: "submission-order"),
            caller: fixture.plannerCaller
        )
        let committedState = await stateIterator.next()
        let effect = await effectIterator.next()

        #expect(committedState?.revision == result.revision)
        #expect(committedState?.tasks.first?.status == .dispatching)
        #expect(effect == .dispatch(
            taskID: result.taskIDs[0],
            workerID: "worker-1",
            bindingID: "binding-worker-1"
        ))
    }

    @Test func concurrentCommandsCommitStrictlyIncreasingRevisions() async throws {
        let fixture = try CoordinatorFixture.make()
        let coordinator = fixture.coordinator()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    try await coordinator.pause(cause: "pause-\(index)")
                }
            }
            try await group.waitForAll()
        }

        let revisions = try fixture.persistence.savedStates().map(\.revision)
        #expect(revisions == Array(1...10).map(UInt64.init))
        #expect(await coordinator.snapshot().revision == 10)
    }
}

private struct CoordinatorFixture {
    let workspaceID: UUID
    let persistenceID: UUID
    let plannerSurfaceID: UUID
    let workerSurfaceID: UUID
    let plannerBinding: AgentQueueAgentBinding
    let workerBinding: AgentQueueAgentBinding
    let persistence: RecordingAgentQueuePersistence
    var state: AgentQueueState

    var plannerCaller: AgentQueueCallerContext {
        .init(workspaceID: workspaceID, surfaceID: plannerSurfaceID)
    }

    var workerCaller: AgentQueueCallerContext {
        .init(workspaceID: workspaceID, surfaceID: workerSurfaceID)
    }

    static func make(taskCount: Int = 0) throws -> CoordinatorFixture {
        let now = Date(timeIntervalSince1970: 1_784_006_400)
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let persistenceID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let plannerSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workerSurfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
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
        let persistence = try RecordingAgentQueuePersistence()
        return CoordinatorFixture(
            workspaceID: workspaceID,
            persistenceID: persistenceID,
            plannerSurfaceID: plannerSurfaceID,
            workerSurfaceID: workerSurfaceID,
            plannerBinding: plannerBinding,
            workerBinding: workerBinding,
            persistence: persistence,
            state: AgentQueueState(
                queue: queue,
                tasks: tasks,
                workers: [worker],
                bindings: [plannerBinding, workerBinding],
                events: []
            )
        )
    }

    func coordinator() -> AgentQueueCoordinator {
        AgentQueueCoordinator(
            workspaceID: workspaceID,
            persistenceID: persistenceID,
            legacyWorkspaceID: nil,
            initialState: state,
            persistence: persistence,
            now: { Date(timeIntervalSince1970: 1_784_006_400) }
        )
    }

    func enqueueRequest(submissionID: String) -> AgentQueueEnqueueRequest {
        AgentQueueEnqueueRequest(
            submissionID: submissionID,
            tasks: [
                AgentQueueTaskDraft(
                    title: "Task",
                    body: "Exact body \\ \"quotes\" 작업",
                    executionMode: .parallelAllowed,
                    timeoutSeconds: 1_800,
                    retryLimit: 1
                ),
            ]
        )
    }

    mutating func assignFirstTask() {
        state.tasks[0].status = .dispatched
        state.tasks[0].assignedWorkerSurfaceID = workerSurfaceID
        state.tasks[0].dispatchedAt = state.queue.updatedAt
        state.workers[0].status = .running
        state.workers[0].currentTaskID = state.tasks[0].id
    }
}

private enum ExpectedCoordinatorError {
    case conflict
    case invalidRequest
    case unauthorized
    case staleBinding
}

private func expectCoordinatorError(
    _ expected: ExpectedCoordinatorError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected AgentQueueCoordinatorError")
    } catch let error as AgentQueueCoordinatorError {
        switch (expected, error) {
        case (.conflict, .conflict),
             (.invalidRequest, .invalidRequest),
             (.unauthorized, .unauthorized),
             (.staleBinding, .staleBinding):
            break
        default:
            Issue.record("Unexpected coordinator error: \(error)")
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private actor StreamProbe<Value: Sendable> {
    private var storage: [Value] = []

    func append(_ value: Value) {
        storage.append(value)
    }

    func values() -> [Value] {
        storage
    }
}

private enum RecordingPersistenceError: Error {
    case injected
}

private struct RecordingAgentQueuePersistence: AgentQueuePersisting {
    let rootDirectory: URL

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-queue-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func load(persistenceID: UUID, legacyWorkspaceID: UUID?) throws -> Data? {
        let stableURL = stateURL(id: persistenceID)
        if FileManager.default.fileExists(atPath: stableURL.path) {
            return try Data(contentsOf: stableURL)
        }
        guard let legacyWorkspaceID else { return nil }
        let legacyURL = stateURL(id: legacyWorkspaceID)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }
        return try Data(contentsOf: legacyURL)
    }

    func save(_ data: Data, persistenceID: UUID) throws {
        if FileManager.default.fileExists(atPath: failureURL.path) {
            throw RecordingPersistenceError.injected
        }
        let nextIndex = try savedStates().count + 1
        try data.write(to: rootDirectory.appendingPathComponent("save-\(nextIndex).json"))
        try data.write(to: stateURL(id: persistenceID), options: .atomic)
    }

    func removeLegacyState(workspaceID: UUID) throws {
        let url = stateURL(id: workspaceID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func setFailureEnabled(_ enabled: Bool) throws {
        if enabled {
            try Data().write(to: failureURL)
        } else if FileManager.default.fileExists(atPath: failureURL.path) {
            try FileManager.default.removeItem(at: failureURL)
        }
    }

    func savedStates() throws -> [AgentQueueState] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )
        return try urls
            .filter { $0.lastPathComponent.hasPrefix("save-") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { try JSONDecoder.agentQueue.decode(AgentQueueState.self, from: Data(contentsOf: $0)) }
    }

    private var failureURL: URL {
        rootDirectory.appendingPathComponent("fail")
    }

    private func stateURL(id: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }
}
