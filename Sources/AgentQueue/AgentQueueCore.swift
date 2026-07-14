import Foundation

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

struct AgentQueueReduceResult: Equatable, Sendable {
    var state: AgentQueueState
    var effects: [AgentQueueSideEffect]
}

struct AgentQueueCore: Sendable {
    func reduce(
        state: AgentQueueState,
        event: AgentQueueInputEvent,
        now: Date
    ) -> AgentQueueReduceResult {
        var state = state
        var effects: [AgentQueueSideEffect] = []

        switch event {
        case let .tasksEnqueued(tasks, submission):
            state.tasks.append(contentsOf: tasks)
            state.submissions.append(submission)
            if state.queue.status == .running {
                effects = scheduleNextTasks(state: &state, now: now)
            }

        case .queuePaused:
            state.queue.status = .paused

        case .queueResumed:
            state.queue.status = .running
            effects = scheduleNextTasks(state: &state, now: now)

        case let .bindingsPrepared(bindings):
            applyPreparedBindings(bindings, to: &state)

        case let .agentReady(bindingID):
            markAgentReady(bindingID: bindingID, in: &state, now: now)
            if state.queue.status == .running {
                effects = scheduleNextTasks(state: &state, now: now)
            }

        case let .agentRemoved(agentID, bindingID, cause):
            removeAgent(
                agentID: agentID,
                bindingID: bindingID,
                cause: cause,
                from: &state
            )
            if state.queue.status == .running {
                effects = scheduleNextTasks(state: &state, now: now)
            }

        case let .dispatchSubmitted(taskID, workerID, bindingID, _):
            guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
                  let workerIndex = currentWorkerIndex(
                    workerID: workerID,
                    bindingID: bindingID,
                    in: state
                  ),
                  state.tasks[taskIndex].status == .dispatching,
                  state.workers[workerIndex].currentTaskID == taskID else { break }
            state.tasks[taskIndex].status = .dispatched
            state.tasks[taskIndex].dispatchedAt = now
            state.tasks[taskIndex].dispatchAttemptCount += 1
            state.tasks[taskIndex].assignedWorkerSurfaceID = state.workers[workerIndex].surfaceID
            state.workers[workerIndex].status = .running
            state.workers[workerIndex].lastSeenAt = now

        case let .dispatchSubmissionFailed(taskID, workerID, bindingID, message):
            blockTask(taskID: taskID, message: message, in: &state)
            removeWorker(workerID: workerID, bindingID: bindingID, from: &state)
            state.queue.status = .paused

        case let .taskReported(report):
            effects = applyReport(report, to: &state, now: now)

        case let .recoverySubmitted(taskID, workerID, bindingID):
            guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
                  let workerIndex = currentWorkerIndex(
                    workerID: workerID,
                    bindingID: bindingID,
                    in: state
                  ),
                  state.tasks[taskIndex].status == .retrying,
                  state.workers[workerIndex].currentTaskID == taskID else { break }
            state.tasks[taskIndex].status = .dispatched
            state.tasks[taskIndex].dispatchedAt = now
            state.workers[workerIndex].status = .running
            state.workers[workerIndex].lastSeenAt = now

        case let .recoverySubmissionFailed(taskID, workerID, bindingID, message):
            blockTask(taskID: taskID, message: message, in: &state)
            removeWorker(workerID: workerID, bindingID: bindingID, from: &state)
            state.queue.status = .paused

        case let .taskTimedOut(taskID, bindingID):
            guard let worker = state.workers.first(where: {
                $0.currentTaskID == taskID && $0.bindingID == bindingID
            }) else { break }
            blockTask(taskID: taskID, message: "timeout", in: &state)
            removeWorker(workerID: worker.id, bindingID: bindingID, from: &state)
            state.queue.status = .paused

        case let .taskCancelled(taskID):
            guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) else { break }
            state.tasks[taskIndex].status = .cancelled
            releaseWorker(forTaskID: taskID, in: &state)
            if state.queue.status == .running {
                effects = scheduleNextTasks(state: &state, now: now)
            }

        }

        appendEvents(for: event, state: &state, now: now)
        state.queue.updatedAt = now
        return AgentQueueReduceResult(state: state, effects: effects)
    }

    static func reduce(
        state: AgentQueueState,
        event: AgentQueueInputEvent,
        now: Date
    ) -> AgentQueueReduceResult {
        AgentQueueCore().reduce(state: state, event: event, now: now)
    }

    private func applyPreparedBindings(
        _ bindings: [AgentQueueAgentBinding],
        to state: inout AgentQueueState
    ) {
        for binding in bindings {
            if binding.role == .planner {
                state.bindings.removeAll { $0.role == .planner }
            } else {
                state.bindings.removeAll { $0.role == .worker && $0.agentID == binding.agentID }
            }
            state.bindings.append(binding)

            guard binding.role == .worker,
                  let workerIndex = state.workers.firstIndex(where: { $0.id == binding.agentID }) else {
                continue
            }
            state.workers[workerIndex].bindingID = binding.bindingID
            state.workers[workerIndex].status = .offline
            state.workers[workerIndex].currentTaskID = nil
        }
    }

    private func markAgentReady(
        bindingID: String,
        in state: inout AgentQueueState,
        now: Date
    ) {
        guard let bindingIndex = state.bindings.firstIndex(where: { $0.bindingID == bindingID }) else {
            return
        }
        state.bindings[bindingIndex].readiness = .ready
        state.bindings[bindingIndex].readyAt = now
        state.bindings[bindingIndex].lastSeenAt = now

        let binding = state.bindings[bindingIndex]
        guard binding.role == .worker,
              let surfaceID = binding.surfaceID,
              let workerIndex = state.workers.firstIndex(where: {
                  $0.id == binding.agentID && $0.surfaceID == surfaceID
              }) else { return }
        state.workers[workerIndex].bindingID = bindingID
        if state.workers[workerIndex].currentTaskID == nil {
            state.workers[workerIndex].status = .idle
        }
        state.workers[workerIndex].lastSeenAt = now
    }

    private func removeAgent(
        agentID: String,
        bindingID: String?,
        cause: String,
        from state: inout AgentQueueState
    ) {
        guard let bindingIndex = state.bindings.firstIndex(where: {
            $0.agentID == agentID && (bindingID == nil || $0.bindingID == bindingID)
        }) else { return }

        if state.bindings[bindingIndex].role == .planner {
            state.bindings[bindingIndex].paneID = nil
            state.bindings[bindingIndex].surfaceID = nil
            state.bindings[bindingIndex].readiness = .notReady
            state.bindings[bindingIndex].readyDeadline = nil
            state.bindings[bindingIndex].readyAt = nil
            state.queue.status = .paused
            return
        }

        if let worker = state.workers.first(where: { $0.id == agentID }),
           let taskID = worker.currentTaskID,
           let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
           !state.tasks[taskIndex].status.isTerminal {
            state.tasks[taskIndex].status = .blocked
            state.tasks[taskIndex].lastError = cause
            state.queue.status = .paused
        }
        state.bindings.remove(at: bindingIndex)
        state.workers.removeAll { $0.id == agentID }
    }

    private func applyReport(
        _ report: AgentQueueTaskReport,
        to state: inout AgentQueueState,
        now: Date
    ) -> [AgentQueueSideEffect] {
        guard let taskIndex = state.tasks.firstIndex(where: { $0.id == report.taskID }),
              !state.tasks[taskIndex].status.isTerminal,
              let workerIndex = state.workers.firstIndex(where: {
                  $0.currentTaskID == report.taskID && $0.bindingID == report.bindingID
              }) else { return [] }

        state.reports.append(report)
        switch report.status {
        case .completed:
            state.tasks[taskIndex].status = .completed
            state.tasks[taskIndex].completedAt = now
            state.tasks[taskIndex].lastError = nil
            releaseWorker(forTaskID: report.taskID, in: &state)
            return scheduleNextTasks(state: &state, now: now)

        case .failed:
            if state.tasks[taskIndex].recoveryAttemptCount < state.tasks[taskIndex].retryLimit,
               let bindingID = state.workers[workerIndex].bindingID {
                state.tasks[taskIndex].status = .retrying
                state.tasks[taskIndex].recoveryAttemptCount += 1
                state.tasks[taskIndex].lastError = report.body
                state.workers[workerIndex].status = .recovering
                return [
                    .recover(
                        taskID: report.taskID,
                        workerID: state.workers[workerIndex].id,
                        bindingID: bindingID
                    ),
                ]
            }
            state.tasks[taskIndex].status = .failed
            state.tasks[taskIndex].lastError = report.body
            releaseWorker(forTaskID: report.taskID, in: &state)
            state.queue.status = .paused
            return []

        case .blocked:
            state.tasks[taskIndex].status = .blocked
            state.tasks[taskIndex].lastError = report.body
            releaseWorker(forTaskID: report.taskID, in: &state)
            state.queue.status = .paused
            return []
        }
    }

    private func scheduleNextTasks(
        state: inout AgentQueueState,
        now: Date
    ) -> [AgentQueueSideEffect] {
        guard state.queue.status == .running else { return [] }

        let activeTaskIndices = state.tasks.indices.filter {
            state.tasks[$0].status.isActive
        }
        if activeTaskIndices.contains(where: {
            state.tasks[$0].executionMode == .sequential
        }) {
            return []
        }

        guard let firstQueuedIndex = state.tasks.firstIndex(where: { $0.status == .queued }) else {
            return []
        }
        if state.tasks[..<firstQueuedIndex].contains(where: {
            !$0.status.isTerminal && $0.executionMode == .sequential
        }) {
            return []
        }

        let workerIndices = eligibleWorkerIndices(in: state)
        guard !workerIndices.isEmpty else { return [] }

        if state.tasks[firstQueuedIndex].executionMode == .sequential {
            guard activeTaskIndices.isEmpty else { return [] }
            let workerIndex = workerIndices[0]
            return [assign(taskIndex: firstQueuedIndex, workerIndex: workerIndex, state: &state, now: now)]
        }

        var effects: [AgentQueueSideEffect] = []
        var workerCursor = 0
        var taskIndex = firstQueuedIndex
        while taskIndex < state.tasks.count,
              workerCursor < workerIndices.count,
              state.tasks[taskIndex].status == .queued,
              state.tasks[taskIndex].executionMode == .parallelAllowed {
            effects.append(
                assign(
                    taskIndex: taskIndex,
                    workerIndex: workerIndices[workerCursor],
                    state: &state,
                    now: now
                )
            )
            workerCursor += 1
            taskIndex += 1
        }
        return effects
    }

    private func eligibleWorkerIndices(in state: AgentQueueState) -> [Int] {
        state.workers.indices.filter { index in
            let worker = state.workers[index]
            guard worker.enabled,
                  worker.status == .idle,
                  worker.currentTaskID == nil,
                  let bindingID = worker.bindingID,
                  let binding = state.bindings.first(where: { $0.bindingID == bindingID }) else {
                return false
            }
            return binding.role == .worker
                && binding.readiness == .ready
                && binding.surfaceID == worker.surfaceID
        }
    }

    private func assign(
        taskIndex: Int,
        workerIndex: Int,
        state: inout AgentQueueState,
        now: Date
    ) -> AgentQueueSideEffect {
        let bindingID = state.workers[workerIndex].bindingID!
        state.tasks[taskIndex].status = .dispatching
        state.workers[workerIndex].status = .assigned
        state.workers[workerIndex].currentTaskID = state.tasks[taskIndex].id
        state.workers[workerIndex].lastSeenAt = now
        return .dispatch(
            taskID: state.tasks[taskIndex].id,
            workerID: state.workers[workerIndex].id,
            bindingID: bindingID
        )
    }

    private func currentWorkerIndex(
        workerID: String,
        bindingID: String,
        in state: AgentQueueState
    ) -> Int? {
        state.workers.firstIndex(where: {
            $0.id == workerID && $0.bindingID == bindingID
        })
    }

    private func blockTask(
        taskID: String,
        message: String,
        in state: inout AgentQueueState
    ) {
        guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
              !state.tasks[taskIndex].status.isTerminal else { return }
        state.tasks[taskIndex].status = .blocked
        state.tasks[taskIndex].lastError = message
    }

    private func removeWorker(
        workerID: String,
        bindingID: String,
        from state: inout AgentQueueState
    ) {
        guard state.workers.contains(where: {
            $0.id == workerID && $0.bindingID == bindingID
        }) else { return }
        state.workers.removeAll { $0.id == workerID && $0.bindingID == bindingID }
        state.bindings.removeAll { $0.agentID == workerID && $0.bindingID == bindingID }
    }

    private func releaseWorker(forTaskID taskID: String, in state: inout AgentQueueState) {
        guard let workerIndex = state.workers.firstIndex(where: { $0.currentTaskID == taskID }) else {
            return
        }
        state.workers[workerIndex].status = .idle
        state.workers[workerIndex].currentTaskID = nil
    }

    private func appendEvents(
        for event: AgentQueueInputEvent,
        state: inout AgentQueueState,
        now: Date
    ) {
        switch event {
        case let .tasksEnqueued(tasks, _):
            for task in tasks {
                appendEvent(type: .taskCreated, taskID: task.id, workerID: nil, state: &state, now: now)
            }
        case .queueResumed:
            appendEvent(type: .queueStarted, taskID: nil, workerID: nil, state: &state, now: now)
        case .queuePaused:
            appendEvent(type: .queuePaused, taskID: nil, workerID: nil, state: &state, now: now)
        case let .dispatchSubmitted(taskID, workerID, _, _):
            appendEvent(type: .taskDispatched, taskID: taskID, workerID: workerID, state: &state, now: now)
            appendEvent(type: .enterSubmitted, taskID: taskID, workerID: workerID, state: &state, now: now)
        case let .dispatchSubmissionFailed(taskID, workerID, _, _),
             let .recoverySubmissionFailed(taskID, workerID, _, _):
            appendEvent(type: .taskFailed, taskID: taskID, workerID: workerID, state: &state, now: now)
        case let .taskReported(report):
            appendEvent(
                type: report.status == .completed ? .taskCompleted : .taskFailed,
                taskID: report.taskID,
                workerID: nil,
                state: &state,
                now: now
            )
        case let .recoverySubmitted(taskID, _, _):
            appendEvent(type: .recoverySent, taskID: taskID, workerID: workerIDOrNil(event), state: &state, now: now)
        case let .taskTimedOut(taskID, _):
            appendEvent(type: .timeout, taskID: taskID, workerID: nil, state: &state, now: now)
        case let .taskCancelled(taskID):
            appendEvent(type: .taskCancelled, taskID: taskID, workerID: nil, state: &state, now: now)
        case .bindingsPrepared, .agentReady, .agentRemoved:
            break
        }
    }

    private func workerIDOrNil(_ event: AgentQueueInputEvent) -> String? {
        if case let .recoverySubmitted(_, workerID, _) = event {
            return workerID
        }
        return nil
    }

    private func appendEvent(
        type: AgentQueueLogEventType,
        taskID: String?,
        workerID: String?,
        state: inout AgentQueueState,
        now: Date
    ) {
        state.events.append(
            AgentQueueLogEvent(
                id: String(format: "event-%04d", state.events.count + 1),
                queueID: state.queue.id,
                taskID: taskID,
                workerID: workerID,
                type: type,
                message: "\(type.rawValue)\(taskID.map { " \($0)" } ?? "")",
                evidence: nil,
                createdAt: now
            )
        )
    }
}

private extension AgentTaskStatus {
    var isActive: Bool {
        switch self {
        case .dispatching, .dispatched, .awaitingReport, .retrying:
            true
        case .queued, .completed, .blocked, .failed, .cancelled:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .blocked, .failed, .cancelled:
            true
        case .queued, .dispatching, .dispatched, .awaitingReport, .retrying:
            false
        }
    }
}
