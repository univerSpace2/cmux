import Foundation
import Observation

@MainActor
@Observable
final class AgentQueueController {
    private(set) var state: AgentQueueState
    private(set) var pendingRoleSkillChanges: [AgentQueueRoleSkillChange] = []

    @ObservationIgnored private let coordinator: AgentQueueCoordinator?
    @ObservationIgnored private let effectExecutor: AgentQueueEffectExecutor?
    @ObservationIgnored private var topologyReconciler: AgentQueueTopologyReconciler?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored
    private let paneAdapter: AgentQueuePaneAdapting
    @ObservationIgnored
    private let store: AgentQueueStore?
    @ObservationIgnored
    private let roleSkillInstaller: (any AgentQueueRoleSkillInstalling)?
    @ObservationIgnored
    private let workerPreparer: (any AgentQueueWorkerPreparing)?
    @ObservationIgnored
    private let skillCatalog: AgentQueueSkillCatalog?
    @ObservationIgnored
    private let skillRootDirectory: String?
    @ObservationIgnored
    private let pollInterval: Duration
    @ObservationIgnored
    private let skillSourceExists: @Sendable (String) -> Bool
    @ObservationIgnored
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored
    private let now: () -> Date
    private var nextSequence: Int
    @ObservationIgnored
    private var monitoringTask: Task<Void, Never>?
    private var reportFingerprintOrder: [ReportFingerprint] = []
    private var reportFingerprints: Set<ReportFingerprint> = []
    private var plannerResponseFingerprintOrder: [String] = []
    private var plannerResponseFingerprints: Set<String> = []
    private var plannerCorrectionRequestID: UUID?

    private struct ReportFingerprint: Hashable {
        var taskID: String
        var surfaceID: UUID
        var normalizedExcerpt: String
    }

    init(
        initialState: AgentQueueState,
        paneAdapter: AgentQueuePaneAdapting,
        store: AgentQueueStore?,
        roleSkillInstaller: (any AgentQueueRoleSkillInstalling)? = nil,
        workerPreparer: (any AgentQueueWorkerPreparing)? = nil,
        skillCatalog: AgentQueueSkillCatalog? = nil,
        skillRootDirectory: String? = nil,
        pollInterval: Duration = .seconds(1),
        skillSourceExists: @escaping @Sendable (String) -> Bool = { path in
            AgentQueueSkillPath.exists(path)
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping () -> Date = Date.init,
        coordinator: AgentQueueCoordinator? = nil,
        effectExecutor: AgentQueueEffectExecutor? = nil
    ) {
        state = initialState
        self.coordinator = coordinator
        self.effectExecutor = effectExecutor
        self.paneAdapter = paneAdapter
        self.store = store
        self.roleSkillInstaller = roleSkillInstaller
        self.workerPreparer = workerPreparer
        self.skillCatalog = skillCatalog
        self.skillRootDirectory = skillRootDirectory
        self.pollInterval = pollInterval
        self.skillSourceExists = skillSourceExists
        self.sleep = sleep
        self.now = now
        nextSequence = initialState.tasks.count + 1
    }

    var canStart: Bool {
        guard !hasActiveWork,
              state.tasks.contains(where: { $0.status == .queued }),
              let preparation = state.preparation,
              preparation.isReady(agentID: AgentQueueAgentID.planner),
              preparation.record(agentID: AgentQueueAgentID.planner)?.surfaceID ==
                state.queue.plannerSurfaceID else {
            return false
        }

        let activeWorkerIDs = Array(
            AgentQueueAgentID.workerIDs.prefix(preparation.configuration.workerCount)
        )
        let activeWorkers = activeWorkerIDs.compactMap { agentID in
            state.workers.first(where: { $0.id == agentID })
        }
        guard activeWorkers.count == activeWorkerIDs.count,
              activeWorkers.contains(where: { $0.enabled && $0.status == .idle }) else {
            return false
        }

        return activeWorkers.allSatisfy { worker in
            preparation.isReady(agentID: worker.id) &&
                preparation.record(agentID: worker.id)?.surfaceID == worker.surfaceID
        }
    }

    var canRequestPlan: Bool {
        guard !isPreparationInProgress,
              let preparation = state.preparation,
              preparation.isReady(agentID: AgentQueueAgentID.planner),
              preparation.record(agentID: AgentQueueAgentID.planner)?.surfaceID ==
                state.queue.plannerSurfaceID else {
            return false
        }

        switch state.planningRequest?.phase {
        case .submitting, .waitingForPlanner:
            return false
        case .failed, nil:
            return true
        }
    }

    var hasActiveWork: Bool {
        state.tasks.contains { task in
            switch task.status {
            case .dispatching, .dispatched, .awaitingReport, .retrying:
                return true
            case .queued, .completed, .blocked, .failed, .cancelled:
                return false
            }
        }
    }

    var canEditProfiles: Bool {
        !hasActiveWork && !isPreparationInProgress
    }

    func setWorkerCount(_ count: Int) {
        guard (1...4).contains(count),
              var preparation = state.preparation,
              count != preparation.configuration.workerCount,
              !isPreparationInProgress else {
            return
        }

        let previousCount = preparation.configuration.workerCount
        guard !hasActiveWork || count > previousCount,
              let configuration = try? preparation.configuration.replacingWorkerCount(count) else {
            return
        }

        preparation.configuration = configuration
        preparation.phase = .notPrepared
        preparation.errorMessage = nil

        if count > previousCount {
            for agentID in AgentQueueAgentID.workerIDs[previousCount..<count] {
                var record = preparation.record(agentID: agentID) ??
                    AgentQueueAgentPreparationRecord(
                        agentID: agentID,
                        surfaceID: state.workers.first(where: { $0.id == agentID })?.surfaceID,
                        appliedProfileFingerprint: nil,
                        appliedRoleSkillFingerprint: nil,
                        phase: .notPrepared,
                        errorMessage: nil
                    )
                record.phase = .notPrepared
                record.errorMessage = nil
                preparation = preparation.replacingRecord(record)
            }
        }

        let activeWorkerIDs = Set(AgentQueueAgentID.workerIDs.prefix(count))
        for index in state.workers.indices where !state.workers[index].status.isActiveForPreparation {
            state.workers[index].enabled = activeWorkerIDs.contains(state.workers[index].id)
        }
        state.preparation = preparation
        pendingRoleSkillChanges = []
        if !hasActiveWork {
            state.queue.status = .paused
        }
        state.queue.updatedAt = now()
        persistSoon()
    }

    func addSkill(_ skill: AgentQueueSkillSelection, to agentID: String) {
        guard skillSourceExists(skill.sourcePath) else { return }
        mutateProfile(agentID: agentID) { $0.addingSkill(skill) }
    }

    func removeSkill(sourcePath: String, from agentID: String) {
        mutateProfile(agentID: agentID) { $0.removingSkill(sourcePath: sourcePath) }
    }

    func setRolePrompt(_ rolePrompt: String, for agentID: String) {
        mutateProfile(agentID: agentID) { profile in
            var copy = profile
            copy.rolePrompt = rolePrompt
            return copy
        }
    }

    func setPreparationConfiguration(_ configuration: AgentQueuePreparationConfiguration) {
        state.preparation = AgentQueuePreparationState(
            configuration: configuration,
            phase: .notPrepared,
            completedWorkerCount: 0,
            errorMessage: nil
        )
        pendingRoleSkillChanges = []
        state.queue.status = .paused
        state.queue.updatedAt = now()
        persistSoon()
    }

    func skillOptions(query: String = "") async -> [AgentQueueSkillSelection] {
        guard let skillCatalog else { return [] }
        return await skillCatalog.options(rootDirectory: skillRootDirectory, query: query)
    }

    func prepareWorkers(allowSkillChanges: Bool) async {
        let configuration = state.preparation?.configuration ?? .defaultConfiguration
        updatePreparation(
            configuration: configuration,
            phase: .checkingSkills,
            completedWorkerCount: 0,
            errorMessage: nil
        )

        do {
            let changes: [AgentQueueRoleSkillChange]
            do {
                changes = try await roleSkillInstaller?.pendingChanges() ?? []
            } catch {
                throw AgentQueuePreparationError.skillInstallationFailed(error.localizedDescription)
            }
            pendingRoleSkillChanges = changes

            if !changes.isEmpty && !allowSkillChanges {
                updatePreparation(
                    configuration: configuration,
                    phase: .awaitingSkillConfirmation,
                    completedWorkerCount: 0,
                    errorMessage: nil
                )
                persistSoon()
                return
            }

            if !changes.isEmpty {
                do {
                    try await roleSkillInstaller?.apply(changes)
                } catch {
                    throw AgentQueuePreparationError.skillInstallationFailed(error.localizedDescription)
                }
            }
            pendingRoleSkillChanges = []

            var preparation = state.preparation ?? AgentQueuePreparationState(
                configuration: configuration,
                phase: .checkingSkills,
                completedWorkerCount: 0,
                errorMessage: nil
            )
            preparation.desiredRoleSkillFingerprints = try await roleSkillFingerprints(
                preserving: preparation.desiredRoleSkillFingerprints
            )

            var missingSkillAgentIDs: Set<String> = []
            for agentID in configuration.activeAgentIDs {
                guard let profile = configuration.profile(id: agentID),
                      let missingSkill = profile.additionalSkills.first(where: {
                          !skillSourceExists($0.sourcePath)
                      }) else {
                    continue
                }
                missingSkillAgentIDs.insert(agentID)
                var record = preparation.record(agentID: agentID) ??
                    preparationRecord(agentID: agentID)
                record.phase = .failed
                record.errorMessage = missingSkillErrorMessage(path: missingSkill.sourcePath)
                preparation = preparation.replacingRecord(record)
            }

            var agentIDsToPrepare: Set<String> = []
            for agentID in configuration.activeAgentIDs where !missingSkillAgentIDs.contains(agentID) {
                if await requiresPreparation(agentID: agentID, preparation: preparation) {
                    agentIDsToPrepare.insert(agentID)
                }
            }
            for agentID in agentIDsToPrepare {
                var record = preparation.record(agentID: agentID) ??
                    preparationRecord(agentID: agentID)
                record.phase = .preparing
                record.errorMessage = nil
                preparation = preparation.replacingRecord(record)
            }
            state.preparation = preparation

            let requiresWorkerReconciliation = workerSlotsRequireReconciliation(configuration: configuration)
            guard !agentIDsToPrepare.isEmpty || requiresWorkerReconciliation else {
                finalizePreparationState()
                if state.preparation?.phase == .failed {
                    state.queue.status = .paused
                }
                state.queue.updatedAt = now()
                persistSoon()
                return
            }

            guard let workerPreparer else {
                throw AgentQueuePreparationError.plannerUnavailable
            }
            let activeWorkerAgentIDs = Set(
                state.workers.compactMap { worker in
                    worker.status.isActiveForPreparation ? worker.id : nil
                }
            )
            let prepared = try await workerPreparer.prepare(
                configuration: configuration,
                plannerSurfaceID: state.queue.plannerSurfaceID,
                existingWorkerSlots: state.workers.map {
                    AgentQueueWorkerSlot(agentID: $0.id, surfaceID: $0.surfaceID)
                },
                activeWorkerAgentIDs: activeWorkerAgentIDs,
                agentIDsToPrepare: agentIDsToPrepare,
                progress: { [weak self] progress in
                    self?.updatePreparationProgress(
                        progress,
                        configuration: configuration,
                        agentIDsToPrepare: agentIDsToPrepare
                    )
                }
            )
            guard prepared.plannerSurfaceID == state.queue.plannerSurfaceID else {
                throw AgentQueuePreparationError.plannerUnavailable
            }

            registerPreparedWorkers(prepared.workerSlots)
            preparation = state.preparation ?? preparation
            let preparedAgentIDs = Set(prepared.preparedAgents.map(\.agentID))
            let failedAgentIDs = Set(prepared.failures.map(\.agentID))

            for preparedAgent in prepared.preparedAgents {
                guard let profile = configuration.profile(id: preparedAgent.agentID),
                      let roleFingerprint = roleFingerprint(
                          agentID: preparedAgent.agentID,
                          in: preparation.desiredRoleSkillFingerprints
                      ) else {
                    continue
                }
                preparation = preparation.replacingRecord(
                    AgentQueueAgentPreparationRecord(
                        agentID: preparedAgent.agentID,
                        surfaceID: preparedAgent.surfaceID,
                        appliedProfileFingerprint: AgentQueueProfileFingerprint.make(profile),
                        appliedRoleSkillFingerprint: roleFingerprint,
                        phase: .ready,
                        errorMessage: nil
                    )
                )
            }

            for failure in prepared.failures {
                var record = preparation.record(agentID: failure.agentID) ??
                    preparationRecord(agentID: failure.agentID, surfaceID: failure.surfaceID)
                record.surfaceID = failure.surfaceID ?? record.surfaceID
                record.phase = .failed
                record.errorMessage = failure.message
                preparation = preparation.replacingRecord(record)
            }

            for agentID in agentIDsToPrepare
            where !preparedAgentIDs.contains(agentID) && !failedAgentIDs.contains(agentID) {
                var record = preparation.record(agentID: agentID) ?? preparationRecord(agentID: agentID)
                record.phase = .failed
                record.errorMessage = missingPreparationResultMessage(agentID: agentID)
                preparation = preparation.replacingRecord(record)
            }
            state.preparation = preparation
            finalizePreparationState()
            if state.preparation?.phase == .failed {
                state.queue.status = .paused
            }
            state.queue.updatedAt = now()
            persistSoon()
            topologyReconciler?.reconcile(cause: "preparation")
        } catch {
            state.queue.status = .paused
            updatePreparation(
                configuration: configuration,
                phase: .failed,
                completedWorkerCount: state.preparation?.completedWorkerCount ?? 0,
                errorMessage: preparationErrorMessage(error)
            )
            state.queue.updatedAt = now()
            persistSoon()
        }
    }

    func restorePersistedState() async {
        guard let store else { return }
        let workspaceID = state.queue.workspaceID
        let loaded: AgentQueueState?
        do {
            loaded = try await store.load(workspaceID: workspaceID)
        } catch {
            var preparation = state.preparation ?? AgentQueuePreparationState(
                configuration: .defaultConfiguration,
                phase: .failed,
                completedWorkerCount: 0,
                errorMessage: nil
            )
            preparation.phase = .failed
            preparation.completedWorkerCount = 0
            preparation.errorMessage = restorationErrorMessage(error)
            state.preparation = preparation
            state.queue.status = .paused
            state.queue.updatedAt = now()
            pendingRoleSkillChanges = []
            return
        }
        guard var restored = loaded,
              restored.queue.workspaceID == workspaceID else { return }

        let plannerAvailable = await isAvailableTerminal(restored.queue.plannerSurfaceID)
        var availableWorkers: [AgentWorker] = []
        if restored.preparation != nil {
            for worker in restored.workers {
                if await isAvailableTerminal(worker.surfaceID) {
                    availableWorkers.append(worker)
                }
            }
        }
        restored.workers = availableWorkers
        restored.queue.status = .paused

        if var preparation = restored.preparation {
            do {
                preparation.desiredRoleSkillFingerprints = try await roleSkillFingerprints(
                    preserving: preparation.desiredRoleSkillFingerprints
                )
            } catch {
                preparation.phase = .failed
                preparation.completedWorkerCount = 0
                preparation.errorMessage = preparationErrorMessage(error)
                restored.preparation = preparation
                state = restored
                pendingRoleSkillChanges = []
                nextSequence = restored.tasks.count + 1
                return
            }

            for agentID in preparation.configuration.activeAgentIDs {
                let expectedSurfaceID: UUID? = if agentID == AgentQueueAgentID.planner {
                    plannerAvailable ? restored.queue.plannerSurfaceID : nil
                } else {
                    availableWorkers.first(where: { $0.id == agentID })?.surfaceID
                }
                var record = preparation.record(agentID: agentID) ??
                    AgentQueueAgentPreparationRecord(
                        agentID: agentID,
                        surfaceID: expectedSurfaceID,
                        appliedProfileFingerprint: nil,
                        appliedRoleSkillFingerprint: nil,
                        phase: .notPrepared,
                        errorMessage: nil
                    )

                if let profile = preparation.configuration.profile(id: agentID),
                   let missingSkill = profile.additionalSkills.first(where: {
                       !skillSourceExists($0.sourcePath)
                   }) {
                    record.surfaceID = expectedSurfaceID
                    record.phase = .failed
                    record.errorMessage = missingSkillErrorMessage(path: missingSkill.sourcePath)
                    preparation = preparation.replacingRecord(record)
                    continue
                }

                let evidenceMatches = expectedSurfaceID != nil &&
                    record.phase == .ready &&
                    record.surfaceID == expectedSurfaceID &&
                    preparation.isReady(agentID: agentID)
                let liveReady = if let expectedSurfaceID, evidenceMatches {
                    await paneAdapter.codexReadiness(surfaceID: expectedSurfaceID) == .idle
                } else {
                    false
                }
                if !evidenceMatches || !liveReady {
                    record.surfaceID = expectedSurfaceID
                    record.phase = .notPrepared
                    record.errorMessage = nil
                }
                preparation = preparation.replacingRecord(record)
            }
            restored.preparation = preparation
        }

        state = restored
        finalizePreparationState()
        pendingRoleSkillChanges = []
        nextSequence = restored.tasks.count + 1
        persistSoon()
    }

    func createTasks(from text: String) {
        let bodies = AgentTaskSplitter.split(text)
        guard !bodies.isEmpty else { return }

        let currentNow = now()
        let tasks = bodies.map { body in
            let id = AgentTaskIDFactory.makeTaskID(now: currentNow, sequence: nextSequence)
            nextSequence += 1
            return AgentTask(
                id: id,
                queueID: state.queue.id,
                title: Self.title(for: body),
                body: body,
                status: .queued,
                executionMode: .sequential,
                assignedWorkerSurfaceID: nil,
                dispatchAttemptCount: 0,
                recoveryAttemptCount: 0,
                timeoutSeconds: 1_800,
                retryLimit: 3,
                createdAt: currentNow,
                dispatchedAt: nil,
                completedAt: nil,
                lastError: nil
            )
        }

        state.tasks.append(contentsOf: tasks)
        for task in tasks {
            state.events.append(
                AgentQueueLogEvent(
                    id: UUID().uuidString,
                    queueID: state.queue.id,
                    taskID: task.id,
                    workerID: nil,
                    type: .taskCreated,
                    message: "created \(task.id)",
                    evidence: nil,
                    createdAt: currentNow
                )
            )
        }
        state.queue.updatedAt = currentNow
        persistSoon()
    }

    @discardableResult
    func requestPlan(for goal: String) async -> Bool {
        let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGoal.isEmpty,
              canRequestPlan,
              let plannerProfile = state.preparation?.configuration.profile(
                  id: AgentQueueAgentID.planner
              ) else {
            return false
        }

        let requestID = UUID()
        let createdAt = now()
        plannerCorrectionRequestID = nil
        state.planningRequest = AgentQueuePlanningRequest(
            requestID: requestID,
            goal: normalizedGoal,
            phase: .submitting,
            createdAt: createdAt,
            errorMessage: nil
        )
        state.queue.updatedAt = createdAt
        persistSoon()

        let prompt = AgentQueueInstructionBuilder.plannerRequest(
            goal: normalizedGoal,
            requestID: requestID,
            profile: plannerProfile
        )
        do {
            _ = try await paneAdapter.submitText(prompt, to: state.queue.plannerSurfaceID)
            guard state.planningRequest?.requestID == requestID else { return false }
            state.planningRequest?.phase = .waitingForPlanner
            state.planningRequest?.errorMessage = nil
            state.queue.updatedAt = now()
            persistSoon()
            return true
        } catch {
            guard state.planningRequest?.requestID == requestID else { return false }
            state.planningRequest?.phase = .failed
            state.planningRequest?.errorMessage = planningSubmissionErrorMessage(error)
            state.queue.updatedAt = now()
            persistSoon()
            return false
        }
    }

    @discardableResult
    func retryPlanningRequest() async -> Bool {
        guard let request = state.planningRequest, request.phase == .failed else {
            return false
        }
        return await requestPlan(for: request.goal)
    }

    func setExecutionMode(taskID: String, mode: AgentTaskExecutionMode) {
        guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard state.tasks[index].status == .queued else { return }

        state.tasks[index].executionMode = mode
        persistSoon()
    }

    func start() async {
        if let coordinator {
            guard stateTask == nil else { return }
            state = await coordinator.snapshot()
            let updates = await coordinator.stateUpdates()
            effectExecutor?.start()
            stateTask = Task { [weak self] in
                for await snapshot in updates {
                    guard !Task.isCancelled else { return }
                    self?.state = snapshot
                }
            }
            return
        }
        guard canStart else { return }
        await apply(.queueStarted)
    }

    func installTopologyReconciler(_ reconciler: AgentQueueTopologyReconciler) {
        topologyReconciler = reconciler
    }

    func startTopologyMonitoring() {
        let processEvents = TerminalController.shared.agentChatTranscriptService?.lifecycleEvents()
            ?? AsyncStream { $0.finish() }
        topologyReconciler?.start(
            surfaceEvents: CmuxEventBus.shared.surfaceClosedEvents(),
            processEvents: processEvents
        )
    }

    func pause() {
        if let coordinator {
            Task { try? await coordinator.pause(cause: "manual") }
            return
        }
        Task { await apply(.queuePaused(cause: "manual")) }
    }

    func resume() {
        guard let coordinator else { return }
        Task { try? await coordinator.resume() }
    }

    func removeRegistration(agentID: String) {
        guard let coordinator else { return }
        Task {
            try? await coordinator.removeAgent(
                agentID: agentID,
                expectedBindingID: nil,
                cause: "manual"
            )
        }
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }

        let pollInterval = pollInterval
        let sleep = sleep
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(pollInterval)
                } catch {
                    return
                }

                guard !Task.isCancelled, let self else { return }
                guard self.hasActiveTasks || self.isWaitingForPlanner else { continue }
                await self.pollReportsOnce(now: self.now())
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        stateTask?.cancel()
        stateTask = nil
        effectExecutor?.stop()
    }

    func apply(_ event: AgentQueueInputEvent) async {
        let result = AgentQueueCore.reduce(state: state, event: event, now: now())
        state = result.state
        await runEffects(result.effects)
    }

    func pollReportsOnce(now pollTime: Date) async {
        let knownTaskIDs = Set(state.tasks.map(\.id))
        let activeWorkerSurfaces = state.workers.compactMap { worker -> UUID? in
            guard worker.enabled else { return nil }
            switch worker.status {
            case .assigned, .running, .awaitingReport, .recovering:
                return worker.surfaceID
            case .idle, .offline:
                return nil
            }
        }
        let surfaces = [state.queue.plannerSurfaceID] + activeWorkerSurfaces

        for surfaceID in surfaces {
            guard let snapshot = try? await paneAdapter.readText(surfaceID: surfaceID, lines: 80) else {
                continue
            }
            if surfaceID == state.queue.plannerSurfaceID {
                await importPlannerTasks(from: snapshot.text)
            }
            let reports = AgentQueueReportDetector.detect(
                in: snapshot.text,
                surfaceID: surfaceID,
                plannerSurfaceID: state.queue.plannerSurfaceID,
                knownTaskIDs: knownTaskIDs
            )
            for report in reports {
                if let task = state.tasks.first(where: { $0.id == report.taskID }), task.status.isTerminal {
                    continue
                }

                let fingerprint = makeFingerprint(
                    taskID: report.taskID,
                    surfaceID: report.surfaceID,
                    excerpt: report.excerpt
                )
                guard remember(fingerprint) else { continue }

                if report.kind == .unmatched {
                    await apply(
                        .ignoredReport(
                            surfaceID: report.surfaceID,
                            excerpt: report.excerpt,
                            reason: "unknown_task_id"
                        )
                    )
                } else {
                    await apply(.reportDetected(report))
                }
            }

            for line in AgentQueueReportDetector.detectMalformedCompletionLines(in: snapshot.text) {
                let fingerprint = makeFingerprint(
                    taskID: "<missing>",
                    surfaceID: surfaceID,
                    excerpt: line
                )
                guard remember(fingerprint) else { continue }
                await apply(
                    .ignoredReport(
                        surfaceID: surfaceID,
                        excerpt: line,
                        reason: "missing_task_id"
                    )
                )
            }
        }

        for task in state.tasks where task.status == .awaitingReport {
            guard let dispatchedAt = task.dispatchedAt else { continue }
            if pollTime.timeIntervalSince(dispatchedAt) >= task.timeoutSeconds {
                await apply(.timeout(taskID: task.id))
            }
        }
    }

    private func runEffects(_ effects: [AgentQueueSideEffect]) async {
        for effect in effects {
            switch effect {
            case let .dispatch(taskID, workerID, bindingID):
                await dispatch(taskID: taskID, workerID: workerID, bindingID: bindingID)

            case let .recover(taskID, workerID, bindingID):
                guard let task = state.tasks.first(where: { $0.id == taskID }),
                      let worker = state.workers.first(where: { $0.id == workerID }) else { continue }
                guard let profile = state.preparation?.configuration.profile(id: worker.id) else {
                    await failForMissingProfile(
                        taskID: taskID,
                        workerID: workerID,
                        bindingID: bindingID
                    )
                    continue
                }
                let text = AgentQueueInstructionBuilder.recoveryPrompt(
                    task: task,
                    profile: profile
                )
                do {
                    _ = try await paneAdapter.submitText(text, to: worker.surfaceID)
                    await apply(
                        .recoverySubmitted(
                            taskID: taskID,
                            workerID: workerID,
                            bindingID: bindingID
                        )
                    )
                } catch {
                    await apply(
                        .recoverySubmissionFailed(
                            taskID: taskID,
                            workerID: workerID,
                            bindingID: bindingID,
                            message: error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func dispatch(taskID: String, workerID: String, bindingID: String) async {
        guard let task = state.tasks.first(where: { $0.id == taskID }),
              let worker = state.workers.first(where: {
                  $0.id == workerID && $0.bindingID == bindingID
              }) else {
            return
        }
        guard let profile = state.preparation?.configuration.profile(id: worker.id) else {
            await failForMissingProfile(
                taskID: taskID,
                workerID: workerID,
                bindingID: bindingID
            )
            return
        }
        let text = AgentQueueInstructionBuilder.workerInstruction(
            context: AgentQueueInstructionContext(
                task: task,
                workerSurfaceID: worker.surfaceID,
                profile: profile
            )
        )
        do {
            let result = try await paneAdapter.submitText(text, to: worker.surfaceID)
            await apply(
                .dispatchSubmitted(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    queued: result.queued
                )
            )
        } catch {
            await apply(
                .dispatchSubmissionFailed(
                    taskID: taskID,
                    workerID: workerID,
                    bindingID: bindingID,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func failForMissingProfile(
        taskID: String,
        workerID: String,
        bindingID: String
    ) async {
        await apply(
            .dispatchSubmissionFailed(
                taskID: taskID,
                workerID: workerID,
                bindingID: bindingID,
                message: "Missing Agent Queue profile for \(workerID)."
            )
        )
    }

    private func persistSoon() {
        guard let store else { return }
        let snapshot = state
        Task {
            try? await store.save(AgentQueueStore.pruneEvents(in: snapshot, limit: 500))
        }
    }

    private func mutateProfile(
        agentID: String,
        transform: (AgentQueueAgentProfile) -> AgentQueueAgentProfile
    ) {
        guard canEditProfiles,
              var preparation = state.preparation,
              let profile = preparation.configuration.profile(id: agentID) else {
            return
        }

        let updatedProfile = transform(profile)
        guard updatedProfile != profile,
              let configuration = try? preparation.configuration.replacingProfile(updatedProfile) else {
            return
        }

        var record = preparation.record(agentID: agentID) ?? AgentQueueAgentPreparationRecord(
            agentID: agentID,
            surfaceID: state.workers.first(where: { $0.id == agentID })?.surfaceID,
            appliedProfileFingerprint: nil,
            appliedRoleSkillFingerprint: nil,
            phase: .notPrepared,
            errorMessage: nil
        )
        record.phase = .notPrepared
        record.errorMessage = nil

        preparation.configuration = configuration
        preparation.phase = .notPrepared
        preparation.errorMessage = nil
        preparation = preparation.replacingRecord(record)
        state.preparation = preparation
        pendingRoleSkillChanges = []
        state.queue.status = .paused
        state.queue.updatedAt = now()
        persistSoon()
    }

    private func roleSkillFingerprints(
        preserving existing: [String: String]
    ) async throws -> [String: String] {
        guard let roleSkillInstaller else { return existing }
        do {
            return [
                AgentQueueRoleSkill.planner.rawValue: try await roleSkillInstaller.fingerprint(
                    for: .planner
                ),
                AgentQueueRoleSkill.worker.rawValue: try await roleSkillInstaller.fingerprint(
                    for: .worker
                ),
            ]
        } catch {
            throw AgentQueuePreparationError.skillInstallationFailed(error.localizedDescription)
        }
    }

    private func roleFingerprint(
        agentID: String,
        in fingerprints: [String: String]
    ) -> String? {
        let role = agentID == AgentQueueAgentID.planner
            ? AgentQueueRoleSkill.planner
            : AgentQueueRoleSkill.worker
        return fingerprints[role.rawValue]
    }

    private func expectedSurfaceID(agentID: String) -> UUID? {
        if agentID == AgentQueueAgentID.planner {
            return state.queue.plannerSurfaceID
        }
        return state.workers.first(where: { $0.id == agentID })?.surfaceID
    }

    private func preparationRecord(
        agentID: String,
        surfaceID: UUID? = nil
    ) -> AgentQueueAgentPreparationRecord {
        AgentQueueAgentPreparationRecord(
            agentID: agentID,
            surfaceID: surfaceID ?? expectedSurfaceID(agentID: agentID),
            appliedProfileFingerprint: nil,
            appliedRoleSkillFingerprint: nil,
            phase: .notPrepared,
            errorMessage: nil
        )
    }

    private func requiresPreparation(
        agentID: String,
        preparation: AgentQueuePreparationState
    ) async -> Bool {
        guard preparation.isReady(agentID: agentID),
              let expectedSurfaceID = expectedSurfaceID(agentID: agentID),
              preparation.record(agentID: agentID)?.surfaceID == expectedSurfaceID else {
            return true
        }
        return await paneAdapter.codexReadiness(surfaceID: expectedSurfaceID) != .idle
    }

    private func workerSlotsRequireReconciliation(
        configuration: AgentQueuePreparationConfiguration
    ) -> Bool {
        let desiredIDs = Array(AgentQueueAgentID.workerIDs.prefix(configuration.workerCount))
        return state.workers.map(\.id) != desiredIDs
    }

    private func finalizePreparationState() {
        guard var preparation = state.preparation else { return }
        let activeRecords = preparation.configuration.activeAgentIDs.compactMap {
            preparation.record(agentID: $0)
        }
        let failures = activeRecords.filter { $0.phase == .failed }
        preparation.completedWorkerCount = AgentQueueAgentID.workerIDs
            .prefix(preparation.configuration.workerCount)
            .filter { preparation.isReady(agentID: $0) }
            .count
        if !failures.isEmpty {
            preparation.phase = .failed
            preparation.errorMessage = failures.compactMap(\.errorMessage).joined(separator: "\n")
        } else if preparation.dirtyAgentIDs().isEmpty {
            preparation.phase = .ready
            preparation.errorMessage = nil
        } else {
            preparation.phase = .notPrepared
            preparation.errorMessage = nil
        }
        state.preparation = preparation
    }

    private func missingSkillErrorMessage(path: String) -> String {
        String(
            format: String(
                localized: "agentQueue.profile.missingSkillFormat",
                defaultValue: "스킬을 찾을 수 없음: %@"
            ),
            path
        )
    }

    private func missingPreparationResultMessage(agentID: String) -> String {
        String(
            format: String(
                localized: "agentQueue.preparation.error.missingAgentResult",
                defaultValue: "Agent 준비 결과가 없습니다: %@"
            ),
            agentID
        )
    }

    private func restorationErrorMessage(_ error: Error) -> String {
        String(
            format: String(
                localized: "agentQueue.preparation.error.restoration",
                defaultValue: "Agent Queue 상태를 복원하지 못했습니다: %@"
            ),
            error.localizedDescription
        )
    }

    private func updatePreparation(
        configuration: AgentQueuePreparationConfiguration,
        phase: AgentQueuePreparationPhase,
        completedWorkerCount: Int,
        errorMessage: String?
    ) {
        var preparation = state.preparation ?? AgentQueuePreparationState(
            configuration: configuration,
            phase: phase,
            completedWorkerCount: completedWorkerCount,
            errorMessage: errorMessage
        )
        preparation.configuration = configuration
        preparation.phase = phase
        preparation.completedWorkerCount = completedWorkerCount
        preparation.errorMessage = errorMessage
        state.preparation = preparation
    }

    private func updatePreparationProgress(
        _ progress: AgentQueuePreparationProgress,
        configuration: AgentQueuePreparationConfiguration,
        agentIDsToPrepare: Set<String>
    ) {
        updatePreparation(
            configuration: configuration,
            phase: progress.phase,
            completedWorkerCount: progress.completedWorkerCount,
            errorMessage: nil
        )
        guard let currentAgentID = progress.agentID,
              var preparation = state.preparation else { return }
        for agentID in agentIDsToPrepare {
            var record = preparation.record(agentID: agentID) ?? preparationRecord(agentID: agentID)
            record.phase = agentID == currentAgentID ? .preparing : .notPrepared
            preparation = preparation.replacingRecord(record)
        }
        state.preparation = preparation
    }

    private func registerPreparedWorkers(_ slots: [AgentQueueWorkerSlot]) {
        let existingByAgentID = Dictionary(uniqueKeysWithValues: state.workers.map { ($0.id, $0) })
        let currentNow = now()
        state.workers = slots.map { slot in
            let index = AgentQueueAgentID.workerIDs.firstIndex(of: slot.agentID) ?? 0
            if var existing = existingByAgentID[slot.agentID] {
                existing.workspaceID = state.queue.workspaceID
                existing.paneID = slot.surfaceID
                existing.surfaceID = slot.surfaceID
                existing.label = Self.workerLabel(index: index)
                existing.enabled = true
                existing.lastSeenAt = currentNow
                return existing
            }
            return AgentWorker(
                id: slot.agentID,
                workspaceID: state.queue.workspaceID,
                paneID: slot.surfaceID,
                surfaceID: slot.surfaceID,
                label: Self.workerLabel(index: index),
                enabled: true,
                status: .idle,
                currentTaskID: nil,
                lastSeenAt: currentNow
            )
        }
    }

    private func isAvailableTerminal(_ surfaceID: UUID) async -> Bool {
        do {
            _ = try await paneAdapter.readText(surfaceID: surfaceID, lines: 1)
            return true
        } catch {
            return false
        }
    }

    private func preparationErrorMessage(_ error: Error) -> String {
        guard let error = error as? AgentQueuePreparationError else {
            return error.localizedDescription
        }
        switch error {
        case let .invalidWorkerCount(count):
            return String(
                format: String(
                    localized: "agentQueue.preparation.error.invalidWorkerCount",
                    defaultValue: "Worker 수 %d은(는) 지원되지 않습니다."
                ),
                count
            )
        case .invalidAgentProfiles:
            return String(
                localized: "agentQueue.preparation.error.invalidProfiles",
                defaultValue: "Agent profile configuration is invalid."
            )
        case let .activeWorkerWouldClose(surfaceID):
            return String(
                format: String(
                    localized: "agentQueue.preparation.error.activeWorkerWouldClose",
                    defaultValue: "작업 중인 worker %@을(를) 닫을 수 없습니다."
                ),
                surfaceID.uuidString.lowercased()
            )
        case .plannerUnavailable:
            return String(
                localized: "agentQueue.preparation.error.plannerUnavailable",
                defaultValue: "Planner terminal을 사용할 수 없습니다."
            )
        case .plannerBusy:
            return String(
                localized: "agentQueue.preparation.error.plannerBusy",
                defaultValue: "Planner Codex가 작업 중입니다."
            )
        case let .codexReadinessTimedOut(surfaceID):
            return String(
                format: String(
                    localized: "agentQueue.preparation.error.codexTimeout",
                    defaultValue: "Codex 준비 대기 시간이 초과되었습니다: %@"
                ),
                surfaceID.uuidString.lowercased()
            )
        case let .skillInstallationFailed(message):
            return String(
                format: String(
                    localized: "agentQueue.preparation.error.skillInstallation",
                    defaultValue: "역할 스킬 설치에 실패했습니다: %@"
                ),
                message
            )
        }
    }

    private var hasActiveTasks: Bool {
        hasActiveWork
    }

    private var isWaitingForPlanner: Bool {
        state.planningRequest?.phase == .waitingForPlanner
    }

    private var isPreparationInProgress: Bool {
        guard let phase = state.preparation?.phase else { return false }
        switch phase {
        case .checkingSkills,
             .awaitingSkillConfirmation,
             .startingPlanner,
             .startingWorkers,
             .applyingSkills,
             .waitingForIdle:
            return true
        case .notPrepared, .ready, .failed:
            return false
        }
    }

    private func importPlannerTasks(from text: String) async {
        guard let request = state.planningRequest,
              request.phase == .waitingForPlanner,
              let detection = AgentQueuePlanDetector.detect(in: text) else {
            return
        }

        switch detection {
        case .success(let planned):
            guard planned.requestID == request.requestID else { return }
            let currentNow = now()
            let tasks = planned.tasks.map { plannedTask in
                let id = AgentTaskIDFactory.makeTaskID(now: currentNow, sequence: nextSequence)
                nextSequence += 1
                return AgentTask(
                    id: id,
                    queueID: state.queue.id,
                    title: plannedTask.title,
                    body: plannedTask.body,
                    status: .queued,
                    executionMode: .sequential,
                    assignedWorkerSurfaceID: nil,
                    dispatchAttemptCount: 0,
                    recoveryAttemptCount: 0,
                    timeoutSeconds: 1_800,
                    retryLimit: 3,
                    createdAt: currentNow,
                    dispatchedAt: nil,
                    completedAt: nil,
                    lastError: nil
                )
            }
            state.tasks.append(contentsOf: tasks)
            state.events.append(contentsOf: tasks.map { task in
                AgentQueueLogEvent(
                    id: UUID().uuidString,
                    queueID: state.queue.id,
                    taskID: task.id,
                    workerID: nil,
                    type: .taskCreated,
                    message: "created \(task.id)",
                    evidence: nil,
                    createdAt: currentNow
                )
            })
            state.planningRequest = nil
            plannerCorrectionRequestID = nil
            state.queue.updatedAt = currentNow
            persistSoon()

        case .failure(let error):
            await recoverPlannerResponseIfPossible(from: text, request: request, error: error)
        }
    }

    private func recoverPlannerResponseIfPossible(
        from text: String,
        request: AgentQueuePlanningRequest,
        error: AgentQueuePlanDetectionError
    ) async {
        guard error == .malformedJSON,
              let fingerprint = AgentQueuePlanDetector.normalizedLatestPayload(in: text) else {
            failPlannerResponse(requestID: request.requestID, error: error)
            return
        }

        let requestIDText = request.requestID.uuidString.lowercased()
        if fingerprint.contains("\"request_id\"") &&
            !fingerprint.localizedCaseInsensitiveContains(requestIDText) {
            return
        }
        guard fingerprint.localizedCaseInsensitiveContains(requestIDText),
              fingerprint.contains("\"tasks\"") else {
            failPlannerResponse(requestID: request.requestID, error: error)
            return
        }
        guard rememberPlannerResponseFingerprint(fingerprint) else { return }
        guard plannerCorrectionRequestID != request.requestID else {
            failPlannerResponse(requestID: request.requestID, error: error)
            return
        }

        plannerCorrectionRequestID = request.requestID
        let correction = AgentQueueInstructionBuilder.plannerJSONCorrectionRequest(
            requestID: request.requestID
        )
        do {
            _ = try await paneAdapter.submitText(correction, to: state.queue.plannerSurfaceID)
        } catch {
            failPlannerResponse(requestID: request.requestID, error: .malformedJSON)
        }
    }

    private func failPlannerResponse(
        requestID: UUID,
        error: AgentQueuePlanDetectionError
    ) {
        guard var request = state.planningRequest,
              request.requestID == requestID,
              request.phase == .waitingForPlanner else {
            return
        }
        request.phase = .failed
        request.errorMessage = planningResponseErrorMessage(error)
        state.planningRequest = request
        state.queue.updatedAt = now()
        persistSoon()
    }

    private func planningSubmissionErrorMessage(_ error: Error) -> String {
        String(
            format: String(
                localized: "agentQueue.input.submissionFailed",
                defaultValue: "Could not send the goal to Planner: %@"
            ),
            error.localizedDescription
        )
    }

    private func planningResponseErrorMessage(_: AgentQueuePlanDetectionError) -> String {
        return String(
            localized: "agentQueue.input.responseFailed",
            defaultValue: "Could not import the Planner response."
        )
    }

    private func makeFingerprint(taskID: String, surfaceID: UUID, excerpt: String) -> ReportFingerprint {
        ReportFingerprint(
            taskID: taskID,
            surfaceID: surfaceID,
            normalizedExcerpt: excerpt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        )
    }

    private func remember(_ fingerprint: ReportFingerprint) -> Bool {
        guard reportFingerprints.insert(fingerprint).inserted else { return false }

        reportFingerprintOrder.append(fingerprint)
        if reportFingerprintOrder.count > 512 {
            let evicted = reportFingerprintOrder.removeFirst()
            reportFingerprints.remove(evicted)
        }
        return true
    }

    private func rememberPlannerResponseFingerprint(_ fingerprint: String) -> Bool {
        guard plannerResponseFingerprints.insert(fingerprint).inserted else { return false }

        plannerResponseFingerprintOrder.append(fingerprint)
        if plannerResponseFingerprintOrder.count > 64 {
            let evicted = plannerResponseFingerprintOrder.removeFirst()
            plannerResponseFingerprints.remove(evicted)
        }
        return true
    }

    private static func title(for body: String) -> String {
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= 80 { return collapsed }
        return "\(collapsed.prefix(80))…"
    }

    private static func workerLabel(index: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "agentQueue.worker.defaultLabelFormat", defaultValue: "Worker %d"),
            index + 1
        )
    }
}

private extension AgentTaskStatus {
    var isTerminal: Bool {
        switch self {
        case .completed, .blocked, .failed, .cancelled:
            return true
        case .queued, .dispatching, .dispatched, .awaitingReport, .retrying:
            return false
        }
    }
}

private extension AgentWorkerStatus {
    var isActiveForPreparation: Bool {
        switch self {
        case .assigned, .running, .awaitingReport, .recovering:
            return true
        case .idle, .offline:
            return false
        }
    }
}

@MainActor
final class AgentQueueControllerFactory {
    private var controllers: [UUID: AgentQueueController] = [:]
    private let registry: AgentQueueCoordinatorRegistry
    private let persistence: any AgentQueuePersisting
    private let roleSkillInstaller = AgentQueueRoleSkillInstaller()
    private let skillCatalog = AgentQueueSkillCatalog()

    init(
        registry: AgentQueueCoordinatorRegistry,
        persistence: any AgentQueuePersisting = AgentQueueFilePersistence()
    ) {
        self.registry = registry
        self.persistence = persistence
    }

    func controller(workspace: Workspace, tabManager: TabManager) -> AgentQueueController {
        if let existing = controllers[workspace.id] {
            return existing
        }

        let runtime = makeRuntime(
            workspace: workspace,
            tabManager: tabManager,
            persistenceID: workspace.stableId,
            legacyWorkspaceID: nil
        )
        controllers[workspace.id] = runtime.controller
        Task { [weak self, weak controller = runtime.controller] in
            guard let self, let controller else { return }
            try? await runtime.coordinator.restore()
            await registry.register(runtime.coordinator, workspaceID: workspace.id)
            await controller.start()
            controller.startTopologyMonitoring()
        }
        return runtime.controller
    }

    func restorePersistedControllers(
        _ candidates: [AgentQueueRestoreCandidate]
    ) async {
        for candidate in candidates where controllers[candidate.workspace.id] == nil {
            let persistence = persistence
            let persistenceID = candidate.persistenceID
            let legacyWorkspaceID = candidate.legacyWorkspaceID
            let hasPersistedState = await Task.detached(priority: .utility) {
                do {
                    return try persistence.load(
                        persistenceID: persistenceID,
                        legacyWorkspaceID: legacyWorkspaceID
                    ) != nil
                } catch {
                    return false
                }
            }.value
            guard hasPersistedState else { continue }

            let runtime = makeRuntime(
                workspace: candidate.workspace,
                tabManager: candidate.tabManager,
                persistenceID: persistenceID,
                legacyWorkspaceID: legacyWorkspaceID
            )
            controllers[candidate.workspace.id] = runtime.controller
            do {
                try await runtime.coordinator.restore()
            } catch {
                controllers.removeValue(forKey: candidate.workspace.id)
                continue
            }
            await registry.register(
                runtime.coordinator,
                workspaceID: candidate.workspace.id
            )
            await runtime.controller.start()
            runtime.controller.startTopologyMonitoring()
        }
    }

    private func makeRuntime(
        workspace: Workspace,
        tabManager: TabManager,
        persistenceID: UUID,
        legacyWorkspaceID: UUID?
    ) -> (controller: AgentQueueController, coordinator: AgentQueueCoordinator) {
        let initialState = makeInitialState(workspace: workspace)
        let paneAdapter = AppAgentQueuePaneAdapter(tabManager: tabManager)
        let coordinator = AgentQueueCoordinator(
            workspaceID: workspace.id,
            persistenceID: persistenceID,
            legacyWorkspaceID: legacyWorkspaceID,
            initialState: initialState,
            persistence: persistence
        )
        let effectExecutor = AgentQueueEffectExecutor(
            coordinator: coordinator,
            paneAdapter: paneAdapter
        )
        let controller = AgentQueueController(
            initialState: initialState,
            paneAdapter: paneAdapter,
            store: nil,
            roleSkillInstaller: roleSkillInstaller,
            workerPreparer: AgentQueueWorkerPreparationService(
                workspace: workspace,
                tabManager: tabManager
            ),
            skillCatalog: skillCatalog,
            skillRootDirectory: workspace.currentDirectory,
            coordinator: coordinator,
            effectExecutor: effectExecutor
        )
        let topologyReconciler = AgentQueueTopologyReconciler(
            workspaceID: workspace.id,
            coordinator: coordinator,
            liveSurfaceIDs: { [weak workspace] in
                guard let workspace else { return [] }
                return Set(workspace.panels.keys)
            },
            endedBindingIDs: { [weak controller, weak workspace] in
                guard let controller,
                      let workspace,
                      let service = TerminalController.shared.agentChatTranscriptService else {
                    return []
                }
                let endedSessions = Set(
                    service.sessionRecords(workspaceID: workspace.id.uuidString)
                        .filter { $0.state == .ended }
                        .map(\.sessionID)
                )
                return Set(controller.state.bindings.compactMap { binding in
                    guard let sessionID = binding.observedSessionID,
                          endedSessions.contains(sessionID) else { return nil }
                    return binding.bindingID
                })
            }
        )
        controller.installTopologyReconciler(topologyReconciler)
        return (controller, coordinator)
    }

    private func makeInitialState(workspace: Workspace) -> AgentQueueState {
        let currentNow = Date()
        let plannerSurfaceID = workspace.focusedPanelId
            ?? UUID()
        let queue = AgentQueue(
            id: "queue-\(workspace.id.uuidString.lowercased())",
            workspaceID: workspace.id,
            plannerSurfaceID: plannerSurfaceID,
            status: .paused,
            createdAt: currentNow,
            updatedAt: currentNow
        )
        return AgentQueueState(
            queue: queue,
            tasks: [],
            workers: [],
            events: [],
            preparation: AgentQueuePreparationState(
                configuration: .defaultConfiguration,
                phase: .notPrepared,
                completedWorkerCount: 0,
                errorMessage: nil
            )
        )
    }
}
