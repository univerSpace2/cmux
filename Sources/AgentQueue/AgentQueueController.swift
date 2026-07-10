import Combine
import Foundation

@MainActor
final class AgentQueueController: ObservableObject {
    @Published private(set) var state: AgentQueueState
    @Published private(set) var pendingRoleSkillChanges: [AgentQueueRoleSkillChange] = []

    private let paneAdapter: AgentQueuePaneAdapting
    private let store: AgentQueueStore?
    private let roleSkillInstaller: (any AgentQueueRoleSkillInstalling)?
    private let workerPreparer: (any AgentQueueWorkerPreparing)?
    private let skillCatalog: AgentQueueSkillCatalog?
    private let skillRootDirectory: String?
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> Date
    private var nextSequence: Int
    private var monitoringTask: Task<Void, Never>?
    private var reportFingerprintOrder: [ReportFingerprint] = []
    private var reportFingerprints: Set<ReportFingerprint> = []

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
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping () -> Date = Date.init
    ) {
        state = initialState
        self.paneAdapter = paneAdapter
        self.store = store
        self.roleSkillInstaller = roleSkillInstaller
        self.workerPreparer = workerPreparer
        self.skillCatalog = skillCatalog
        self.skillRootDirectory = skillRootDirectory
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
        nextSequence = initialState.tasks.count + 1
    }

    var canStart: Bool {
        state.preparation?.phase == .ready &&
            state.tasks.contains(where: { $0.status == .queued }) &&
            state.workers.contains(where: { $0.enabled && $0.status == .idle })
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

            guard let workerPreparer else {
                throw AgentQueuePreparationError.plannerUnavailable
            }
            let activeWorkerSurfaceIDs = Set(
                state.workers.compactMap { worker in
                    worker.status.isActiveForPreparation ? worker.surfaceID : nil
                }
            )
            let prepared = try await workerPreparer.prepare(
                configuration: configuration,
                plannerSurfaceID: state.queue.plannerSurfaceID,
                existingWorkerSurfaceIDs: state.workers.map(\.surfaceID),
                activeWorkerSurfaceIDs: activeWorkerSurfaceIDs,
                progress: { [weak self] phase, completedWorkerCount in
                    self?.updatePreparation(
                        configuration: configuration,
                        phase: phase,
                        completedWorkerCount: completedWorkerCount,
                        errorMessage: nil
                    )
                }
            )
            guard prepared.plannerSurfaceID == state.queue.plannerSurfaceID else {
                throw AgentQueuePreparationError.plannerUnavailable
            }

            registerPreparedWorkers(prepared.workerSurfaceIDs)
            updatePreparation(
                configuration: configuration,
                phase: .ready,
                completedWorkerCount: prepared.workerSurfaceIDs.count,
                errorMessage: nil
            )
            state.queue.updatedAt = now()
            persistSoon()
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
        guard var restored = try? await store.load(workspaceID: workspaceID),
              restored.queue.workspaceID == workspaceID else {
            return
        }

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
            let hasConfiguredWorkers = availableWorkers.count == preparation.configuration.workerCount
            if !plannerAvailable || !hasConfiguredWorkers || preparation.phase != .ready {
                preparation.phase = .notPrepared
                preparation.completedWorkerCount = 0
                preparation.errorMessage = nil
            }
            restored.preparation = preparation
        }

        state = restored
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

    func setExecutionMode(taskID: String, mode: AgentTaskExecutionMode) {
        guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard state.tasks[index].status == .queued else { return }

        state.tasks[index].executionMode = mode
        persistSoon()
    }

    func start() async {
        guard canStart else { return }
        await apply(.queueStarted)
    }

    func pause() {
        Task { await apply(.queuePaused) }
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
                guard self.hasActiveTasks else { continue }
                await self.pollReportsOnce(now: self.now())
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
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
            case let .dispatch(taskID, workerID):
                await dispatch(taskID: taskID, workerID: workerID)

            case let .forwardReport(taskID, _, excerpt):
                let text = """
                자동 복구 보고 [\(taskID)]:
                Worker pane에서 완료 보고가 감지되어 planner pane으로 전달합니다.

                \(excerpt)

                """
                _ = try? await paneAdapter.sendText(text, to: state.queue.plannerSurfaceID)
                _ = try? await paneAdapter.sendEnter(to: state.queue.plannerSurfaceID)

            case let .sendRecovery(taskID, workerID):
                guard let task = state.tasks.first(where: { $0.id == taskID }),
                      let worker = state.workers.first(where: { $0.id == workerID }) else { continue }
                let text = AgentQueueInstructionBuilder.recoveryPrompt(
                    task: task,
                    additionalSkill: state.preparation?.configuration.additionalSkill
                )
                _ = try? await paneAdapter.sendText(text, to: worker.surfaceID)
                _ = try? await paneAdapter.sendEnter(to: worker.surfaceID)
                await apply(.recoverySent(taskID: taskID))

            case .persist:
                persistSoon()
            }
        }
    }

    private func dispatch(taskID: String, workerID: String) async {
        guard let task = state.tasks.first(where: { $0.id == taskID }),
              let worker = state.workers.first(where: { $0.id == workerID }) else {
            return
        }
        let text = AgentQueueInstructionBuilder.workerInstruction(
            context: AgentQueueInstructionContext(
                task: task,
                workerSurfaceID: worker.surfaceID,
                additionalSkill: state.preparation?.configuration.additionalSkill
            )
        )
        var didSendText = false
        do {
            let textResult = try await paneAdapter.sendText(text, to: worker.surfaceID)
            didSendText = true
            let enterResult = try await paneAdapter.sendEnter(to: worker.surfaceID)
            await apply(
                .dispatchSubmitted(
                    taskID: taskID,
                    workerID: workerID,
                    queued: textResult.queued || enterResult.queued
                )
            )
        } catch {
            await apply(
                .dispatchSubmissionFailed(
                    taskID: taskID,
                    workerID: workerID,
                    stage: didSendText ? .enter : .text,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func persistSoon() {
        guard let store else { return }
        let snapshot = state
        Task {
            try? await store.save(AgentQueueStore.pruneEvents(in: snapshot, limit: 500))
        }
    }

    private func updatePreparation(
        configuration: AgentQueuePreparationConfiguration,
        phase: AgentQueuePreparationPhase,
        completedWorkerCount: Int,
        errorMessage: String?
    ) {
        state.preparation = AgentQueuePreparationState(
            configuration: configuration,
            phase: phase,
            completedWorkerCount: completedWorkerCount,
            errorMessage: errorMessage
        )
    }

    private func registerPreparedWorkers(_ surfaceIDs: [UUID]) {
        let existingBySurfaceID = Dictionary(
            uniqueKeysWithValues: state.workers.map { ($0.surfaceID, $0) }
        )
        let currentNow = now()
        state.workers = surfaceIDs.enumerated().map { index, surfaceID in
            if var existing = existingBySurfaceID[surfaceID] {
                existing.id = "worker-\(index + 1)"
                existing.workspaceID = state.queue.workspaceID
                existing.paneID = surfaceID
                existing.surfaceID = surfaceID
                existing.label = Self.workerLabel(index: index)
                existing.lastSeenAt = currentNow
                return existing
            }
            return AgentWorker(
                id: "worker-\(index + 1)",
                workspaceID: state.queue.workspaceID,
                paneID: surfaceID,
                surfaceID: surfaceID,
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
        state.tasks.contains { task in
            switch task.status {
            case .dispatching, .awaitingReport, .retrying:
                return true
            case .queued, .dispatched, .completed, .blocked, .failed, .cancelled:
                return false
            }
        }
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
    static let shared = AgentQueueControllerFactory()

    private var controllers: [UUID: AgentQueueController] = [:]
    private let store = AgentQueueStore()
    private let roleSkillInstaller = AgentQueueRoleSkillInstaller()
    private let skillCatalog = AgentQueueSkillCatalog()

    func controller(workspace: Workspace, tabManager: TabManager) -> AgentQueueController {
        if let existing = controllers[workspace.id] {
            return existing
        }

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
        let controller = AgentQueueController(
            initialState: AgentQueueState(
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
            ),
            paneAdapter: AppAgentQueuePaneAdapter(tabManager: tabManager),
            store: store,
            roleSkillInstaller: roleSkillInstaller,
            workerPreparer: AgentQueueWorkerPreparationService(
                workspace: workspace,
                tabManager: tabManager
            ),
            skillCatalog: skillCatalog,
            skillRootDirectory: workspace.currentDirectory
        )
        controllers[workspace.id] = controller
        Task { [weak controller] in
            guard let controller else { return }
            await controller.restorePersistedState()
            controller.startMonitoring()
        }
        return controller
    }
}
