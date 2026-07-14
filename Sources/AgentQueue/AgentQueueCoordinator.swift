import CryptoKit
import Foundation

actor AgentQueueCoordinator {
    private let workspaceID: UUID
    private let persistenceID: UUID
    private let legacyWorkspaceID: UUID?
    private let persistence: any AgentQueuePersisting
    private let migration: AgentQueueStateMigration
    private let core: AgentQueueCore
    private let now: @Sendable () -> Date

    private var state: AgentQueueState
    private var stateContinuations: [UUID: AsyncStream<AgentQueueState>.Continuation] = [:]
    private var effectContinuations: [UUID: AsyncStream<AgentQueueSideEffect>.Continuation] = [:]

    init(
        workspaceID: UUID,
        persistenceID: UUID,
        legacyWorkspaceID: UUID?,
        initialState: AgentQueueState,
        persistence: any AgentQueuePersisting,
        migration: AgentQueueStateMigration = .init(),
        core: AgentQueueCore = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.workspaceID = workspaceID
        self.persistenceID = persistenceID
        self.legacyWorkspaceID = legacyWorkspaceID
        self.state = initialState
        self.persistence = persistence
        self.migration = migration
        self.core = core
        self.now = now
    }

    func restore() throws {
        guard let data = try persistence.load(
            persistenceID: persistenceID,
            legacyWorkspaceID: legacyWorkspaceID
        ) else { return }

        let sourceVersion = try migration.schemaVersion(in: data)
        var restored = try migration.decode(data)
        let workspaceChanged = restored.queue.workspaceID != workspaceID
        restored.queue.workspaceID = workspaceID
        for index in restored.bindings.indices {
            restored.bindings[index].workspaceID = workspaceID
        }
        for index in restored.workers.indices {
            restored.workers[index].workspaceID = workspaceID
        }

        if sourceVersion == 1 || workspaceChanged || legacyWorkspaceID != nil {
            let encoded = try JSONEncoder.agentQueue.encode(restored)
            try persistence.save(encoded, persistenceID: persistenceID)
            if let legacyWorkspaceID, legacyWorkspaceID != persistenceID {
                try persistence.removeLegacyState(workspaceID: legacyWorkspaceID)
            }
        }
        state = restored
        yieldState(restored)
    }

    func snapshot() -> AgentQueueState {
        state
    }

    func stateUpdates() -> AsyncStream<AgentQueueState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeStateContinuation(id: id) }
            }
        }
    }

    func effects() -> AsyncStream<AgentQueueSideEffect> {
        let id = UUID()
        return AsyncStream { continuation in
            effectContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeEffectContinuation(id: id) }
            }
        }
    }

    func enqueue(
        _ request: AgentQueueEnqueueRequest,
        caller: AgentQueueCallerContext
    ) throws -> AgentQueueEnqueueResult {
        try authorizePlanner(caller)
        try validate(request)
        let digest = try payloadDigest(request)

        if let existing = state.submissions.first(where: {
            $0.submissionID == request.submissionID
        }) {
            guard existing.payloadDigest == digest else {
                throw AgentQueueCoordinatorError.conflict("submission_id")
            }
            return AgentQueueEnqueueResult(
                submissionID: existing.submissionID,
                taskIDs: existing.taskIDs,
                revision: state.revision,
                idempotent: true
            )
        }

        let timestamp = now()
        let firstSequence = state.tasks.count + 1
        let tasks = request.tasks.enumerated().map { offset, draft in
            AgentTask(
                id: AgentTaskIDFactory.makeTaskID(
                    now: timestamp,
                    sequence: firstSequence + offset
                ),
                queueID: state.queue.id,
                title: draft.title,
                body: draft.body,
                status: .queued,
                executionMode: draft.executionMode,
                assignedWorkerSurfaceID: nil,
                dispatchAttemptCount: 0,
                recoveryAttemptCount: 0,
                timeoutSeconds: draft.timeoutSeconds,
                retryLimit: draft.retryLimit,
                createdAt: timestamp,
                dispatchedAt: nil,
                completedAt: nil,
                lastError: nil
            )
        }
        let submission = AgentQueueSubmission(
            submissionID: request.submissionID,
            payloadDigest: digest,
            taskIDs: tasks.map(\.id),
            createdAt: timestamp
        )
        let reduced = try commit(.tasksEnqueued(tasks: tasks, submission: submission))
        return AgentQueueEnqueueResult(
            submissionID: request.submissionID,
            taskIDs: tasks.map(\.id),
            revision: reduced.state.revision,
            idempotent: false
        )
    }

    func report(
        _ request: AgentQueueReportRequest,
        caller: AgentQueueCallerContext
    ) throws -> AgentQueueReportResult {
        if let existing = state.reports.first(where: { $0.reportID == request.reportID }) {
            guard existing.taskID == request.taskID,
                  existing.status == request.status,
                  existing.body == request.body,
                  existing.bindingID == request.bindingID else {
                throw AgentQueueCoordinatorError.conflict("report_id")
            }
            return AgentQueueReportResult(
                reportID: existing.reportID,
                taskID: existing.taskID,
                status: existing.status,
                revision: state.revision,
                idempotent: true
            )
        }

        let workerIndex = try authorizeWorker(
            bindingID: request.bindingID,
            taskID: request.taskID,
            caller: caller
        )
        guard let taskIndex = state.tasks.firstIndex(where: { $0.id == request.taskID }),
              !isTerminal(state.tasks[taskIndex].status) else {
            throw AgentQueueCoordinatorError.conflict("task")
        }
        let report = AgentQueueTaskReport(
            reportID: request.reportID,
            taskID: request.taskID,
            status: request.status,
            body: request.body,
            bindingID: request.bindingID,
            attemptNumber: state.tasks[taskIndex].recoveryAttemptCount + 1,
            reportedAt: now()
        )
        guard state.workers[workerIndex].currentTaskID == request.taskID else {
            throw AgentQueueCoordinatorError.unauthorized("task_assignment")
        }
        let reduced = try commit(.taskReported(report))
        return AgentQueueReportResult(
            reportID: request.reportID,
            taskID: request.taskID,
            status: request.status,
            revision: reduced.state.revision,
            idempotent: false
        )
    }

    func prepareBindings(_ bindings: [AgentQueueAgentBinding]) throws {
        guard bindings.allSatisfy({ $0.workspaceID == workspaceID }) else {
            throw AgentQueueCoordinatorError.invalidRequest("binding_workspace")
        }
        _ = try commit(.bindingsPrepared(bindings))
    }

    func updatePreparation(
        _ preparation: AgentQueuePreparationState,
        workers: [AgentWorker]? = nil,
        queueStatus: AgentQueueStatus? = nil
    ) throws -> AgentQueueState {
        if let workers {
            guard workers.allSatisfy({ $0.workspaceID == workspaceID }),
                  Set(workers.map(\.id)).count == workers.count else {
                throw AgentQueueCoordinatorError.invalidRequest("preparation_workers")
            }
        }

        var next = state
        next.preparation = preparation
        if let workers {
            next.workers = workers
        }
        if let queueStatus {
            next.queue.status = queueStatus
        }
        next.queue.updatedAt = now()
        return try commitState(next, effects: []).state
    }

    func setExecutionMode(
        taskID: String,
        mode: AgentTaskExecutionMode
    ) throws -> AgentQueueState {
        guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AgentQueueCoordinatorError.notFound("task")
        }
        guard state.tasks[taskIndex].status == .queued else {
            throw AgentQueueCoordinatorError.conflict("task_status")
        }
        var next = state
        next.tasks[taskIndex].executionMode = mode
        next.queue.updatedAt = now()
        return try commitState(next, effects: []).state
    }

    func recordObservedSession(
        bindingID: String,
        sessionID: String
    ) throws -> AgentQueueState {
        guard !sessionID.isEmpty,
              let bindingIndex = state.bindings.firstIndex(where: {
                  $0.bindingID == bindingID
              }) else {
            throw AgentQueueCoordinatorError.notFound("binding")
        }
        var next = state
        next.bindings[bindingIndex].observedSessionID = sessionID
        next.bindings[bindingIndex].lastSeenAt = now()
        return try commitState(next, effects: []).state
    }

    func markReady(
        agentID: String,
        role: AgentQueueAgentRole,
        bindingID: String,
        caller: AgentQueueCallerContext
    ) throws -> AgentQueueAgentBinding {
        guard caller.workspaceID == workspaceID else {
            throw AgentQueueCoordinatorError.unauthorized("workspace")
        }
        guard let binding = state.bindings.first(where: {
            $0.agentID == agentID && $0.bindingID == bindingID
        }) else {
            if state.bindings.contains(where: { $0.agentID == agentID }) {
                throw AgentQueueCoordinatorError.staleBinding(bindingID)
            }
            throw AgentQueueCoordinatorError.notFound("binding")
        }
        guard binding.role == role,
              binding.workspaceID == caller.workspaceID,
              binding.surfaceID == caller.surfaceID else {
            throw AgentQueueCoordinatorError.unauthorized("binding_context")
        }
        guard binding.readiness == .pending else {
            throw AgentQueueCoordinatorError.invalidRequest("binding_readiness")
        }
        let reduced = try commit(.agentReady(bindingID: bindingID))
        guard let updated = reduced.state.bindings.first(where: {
            $0.bindingID == bindingID
        }) else {
            throw AgentQueueCoordinatorError.notFound("binding")
        }
        return updated
    }

    func markOffline(
        agentID: String,
        bindingID: String,
        caller: AgentQueueCallerContext?,
        cause: String
    ) throws {
        guard let binding = state.bindings.first(where: {
            $0.agentID == agentID && $0.bindingID == bindingID
        }) else {
            if state.bindings.contains(where: { $0.agentID == agentID }) {
                throw AgentQueueCoordinatorError.staleBinding(bindingID)
            }
            throw AgentQueueCoordinatorError.notFound("binding")
        }
        if let caller {
            guard caller.workspaceID == workspaceID,
                  caller.workspaceID == binding.workspaceID,
                  caller.surfaceID == binding.surfaceID else {
                throw AgentQueueCoordinatorError.unauthorized("binding_context")
            }
        }
        _ = try commit(
            .agentRemoved(agentID: agentID, bindingID: bindingID, cause: cause)
        )
    }

    func removeAgent(
        agentID: String,
        expectedBindingID: String?,
        cause: String
    ) throws {
        guard let binding = state.bindings.first(where: { $0.agentID == agentID }) else {
            throw AgentQueueCoordinatorError.notFound("binding")
        }
        if let expectedBindingID, expectedBindingID != binding.bindingID {
            throw AgentQueueCoordinatorError.staleBinding(expectedBindingID)
        }
        _ = try commit(
            .agentRemoved(
                agentID: agentID,
                bindingID: expectedBindingID ?? binding.bindingID,
                cause: cause
            )
        )
    }

    func reconcile(
        liveSurfaceIDs: Set<UUID>,
        endedBindingIDs: Set<String>,
        cause: String
    ) throws {
        let removed = state.bindings.filter { binding in
            endedBindingIDs.contains(binding.bindingID)
                || binding.surfaceID.map { !liveSurfaceIDs.contains($0) } == true
        }
        for binding in removed {
            _ = try commit(
                .agentRemoved(
                    agentID: binding.agentID,
                    bindingID: binding.bindingID,
                    cause: cause
                )
            )
        }
    }

    func pause(cause: String) throws {
        _ = try commit(.queuePaused(cause: cause))
    }

    func resume() throws {
        _ = try commit(.queueResumed)
    }

    func recordDispatch(
        taskID: String,
        workerID: String,
        bindingID: String,
        result: Result<AgentQueueSendResult, AgentQueueEffectFailure>
    ) throws {
        switch result {
        case let .success(sendResult):
            _ = try commit(
                .dispatchSubmitted(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    queued: sendResult.queued
                )
            )
        case let .failure(failure):
            _ = try commit(
                .dispatchSubmissionFailed(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    message: failure.message
                )
            )
        }
    }

    func recordRecovery(
        taskID: String,
        workerID: String,
        bindingID: String,
        result: Result<AgentQueueSendResult, AgentQueueEffectFailure>
    ) throws {
        switch result {
        case .success:
            _ = try commit(
                .recoverySubmitted(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID
                )
            )
        case let .failure(failure):
            _ = try commit(
                .recoverySubmissionFailed(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    message: failure.message
                )
            )
        }
    }

    private func commit(_ event: AgentQueueInputEvent) throws -> AgentQueueReduceResult {
        let reduced = core.reduce(state: state, event: event, now: now())
        return try commitState(reduced.state, effects: reduced.effects)
    }

    private func commitState(
        _ proposedState: AgentQueueState,
        effects: [AgentQueueSideEffect]
    ) throws -> AgentQueueReduceResult {
        var next = proposedState
        next.schemaVersion = AgentQueueState.currentSchemaVersion
        next.revision = state.revision + 1
        let data = try JSONEncoder.agentQueue.encode(next)
        try persistence.save(data, persistenceID: persistenceID)
        state = next
        yieldState(state)
        for effect in effects {
            for continuation in effectContinuations.values {
                continuation.yield(effect)
            }
        }
        return AgentQueueReduceResult(state: next, effects: effects)
    }

    private func authorizePlanner(_ caller: AgentQueueCallerContext) throws {
        guard caller.workspaceID == workspaceID,
              state.bindings.contains(where: {
                  $0.role == .planner
                      && $0.workspaceID == caller.workspaceID
                      && $0.surfaceID == caller.surfaceID
                      && $0.readiness == .ready
              }) else {
            throw AgentQueueCoordinatorError.unauthorized("planner")
        }
    }

    private func authorizeWorker(
        bindingID: String,
        taskID: String,
        caller: AgentQueueCallerContext
    ) throws -> Int {
        guard caller.workspaceID == workspaceID else {
            throw AgentQueueCoordinatorError.unauthorized("workspace")
        }
        guard let binding = state.bindings.first(where: {
            $0.bindingID == bindingID
        }) else {
            if state.bindings.contains(where: {
                $0.role == .worker && $0.surfaceID == caller.surfaceID
            }) {
                throw AgentQueueCoordinatorError.staleBinding(bindingID)
            }
            throw AgentQueueCoordinatorError.notFound("binding")
        }
        guard binding.role == .worker,
              binding.readiness == .ready,
              binding.workspaceID == caller.workspaceID,
              binding.surfaceID == caller.surfaceID else {
            throw AgentQueueCoordinatorError.unauthorized("worker")
        }
        guard let workerIndex = state.workers.firstIndex(where: {
            $0.id == binding.agentID
                && $0.bindingID == bindingID
                && $0.currentTaskID == taskID
        }) else {
            throw AgentQueueCoordinatorError.unauthorized("task_assignment")
        }
        return workerIndex
    }

    private func validate(_ request: AgentQueueEnqueueRequest) throws {
        guard !request.submissionID.isEmpty, !request.tasks.isEmpty else {
            throw AgentQueueCoordinatorError.invalidRequest("submission")
        }
        for task in request.tasks {
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !task.body.isEmpty,
                  task.timeoutSeconds > 0,
                  task.retryLimit >= 0 else {
                throw AgentQueueCoordinatorError.invalidRequest("task")
            }
        }
    }

    private func payloadDigest<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.agentQueue.encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isTerminal(_ status: AgentTaskStatus) -> Bool {
        switch status {
        case .completed, .blocked, .failed, .cancelled:
            true
        case .queued, .dispatching, .dispatched, .awaitingReport, .retrying:
            false
        }
    }

    private func yieldState(_ value: AgentQueueState) {
        for continuation in stateContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func removeEffectContinuation(id: UUID) {
        effectContinuations.removeValue(forKey: id)
    }
}
