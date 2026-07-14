import Foundation

@MainActor
final class AgentQueueEffectExecutor {
    private let coordinator: AgentQueueCoordinator
    private let paneAdapter: any AgentQueuePaneAdapting
    private let instructionBuilder: AgentQueueCLIInstructionBuilder
    private var streamTask: Task<Void, Never>?

    init(
        coordinator: AgentQueueCoordinator,
        paneAdapter: any AgentQueuePaneAdapting,
        instructionBuilder: AgentQueueCLIInstructionBuilder = .init()
    ) {
        self.coordinator = coordinator
        self.paneAdapter = paneAdapter
        self.instructionBuilder = instructionBuilder
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self, coordinator] in
            let stream = await coordinator.effects()
            for await effect in stream {
                guard !Task.isCancelled else { return }
                await self?.execute(effect)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func execute(_ effect: AgentQueueSideEffect) async {
        let snapshot = await coordinator.snapshot()
        switch effect {
        case let .dispatch(taskID, workerID, bindingID):
            guard let task = snapshot.tasks.first(where: {
                $0.id == taskID && $0.status == .dispatching
            }),
            let worker = snapshot.workers.first(where: {
                $0.id == workerID
                    && $0.bindingID == bindingID
                    && $0.currentTaskID == taskID
            }),
            snapshot.bindings.contains(where: {
                $0.bindingID == bindingID
                    && $0.agentID == workerID
                    && $0.readiness == .ready
                    && $0.surfaceID == worker.surfaceID
            }),
            let profile = snapshot.preparation?.configuration.profile(id: workerID) else {
                return
            }
            let instruction = instructionBuilder.workerInstruction(
                task: task,
                bindingID: bindingID,
                profile: profile
            )
            do {
                let result = try await paneAdapter.submitText(
                    instruction,
                    to: worker.surfaceID
                )
                try await coordinator.recordDispatch(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    result: .success(result)
                )
            } catch {
                try? await coordinator.recordDispatch(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    result: .failure(
                        AgentQueueEffectFailure(message: error.localizedDescription)
                    )
                )
            }

        case let .recover(taskID, workerID, bindingID):
            guard let task = snapshot.tasks.first(where: {
                $0.id == taskID && $0.status == .retrying
            }),
            let worker = snapshot.workers.first(where: {
                $0.id == workerID
                    && $0.bindingID == bindingID
                    && $0.currentTaskID == taskID
            }),
            snapshot.bindings.contains(where: {
                $0.bindingID == bindingID
                    && $0.agentID == workerID
                    && $0.readiness == .ready
                    && $0.surfaceID == worker.surfaceID
            }),
            let profile = snapshot.preparation?.configuration.profile(id: workerID) else {
                return
            }
            let instruction = instructionBuilder.recoveryInstruction(
                task: task,
                bindingID: bindingID,
                profile: profile
            )
            do {
                let result = try await paneAdapter.submitText(
                    instruction,
                    to: worker.surfaceID
                )
                try await coordinator.recordRecovery(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    result: .success(result)
                )
            } catch {
                try? await coordinator.recordRecovery(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    result: .failure(
                        AgentQueueEffectFailure(message: error.localizedDescription)
                    )
                )
            }
        }
    }
}
