import Foundation
import Observation

@MainActor
@Observable
final class AgentQueueController {
    private(set) var state: AgentQueueState
    private(set) var pendingRoleSkillChanges: [AgentQueueRoleSkillChange] = []

    @ObservationIgnored private let coordinator: AgentQueueCoordinator
    @ObservationIgnored private let effectExecutor: AgentQueueEffectExecutor
    @ObservationIgnored private let paneAdapter: any AgentQueuePaneAdapting
    @ObservationIgnored private let plannerSurfaceID: UUID
    @ObservationIgnored private let roleSkillInstaller: (any AgentQueueRoleSkillInstalling)?
    @ObservationIgnored private let workerPreparer: (any AgentQueueWorkerPreparing)?
    @ObservationIgnored private let skillCatalog: AgentQueueSkillCatalog?
    @ObservationIgnored private let skillRootDirectory: String?
    @ObservationIgnored private let readinessTimeout: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let skillSourceExists: @Sendable (String) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var topologyReconciler: AgentQueueTopologyReconciler?
    @ObservationIgnored private var stateTask: Task<Void, Never>?

    init(
        initialState: AgentQueueState,
        plannerSurfaceID: UUID,
        paneAdapter: any AgentQueuePaneAdapting,
        coordinator: AgentQueueCoordinator,
        effectExecutor: AgentQueueEffectExecutor,
        roleSkillInstaller: (any AgentQueueRoleSkillInstalling)? = nil,
        workerPreparer: (any AgentQueueWorkerPreparing)? = nil,
        skillCatalog: AgentQueueSkillCatalog? = nil,
        skillRootDirectory: String? = nil,
        readinessTimeout: Duration = .seconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        skillSourceExists: @escaping @Sendable (String) -> Bool = { path in
            AgentQueueSkillPath.exists(path)
        },
        now: @escaping () -> Date = Date.init
    ) {
        state = initialState
        self.plannerSurfaceID = plannerSurfaceID
        self.paneAdapter = paneAdapter
        self.coordinator = coordinator
        self.effectExecutor = effectExecutor
        self.roleSkillInstaller = roleSkillInstaller
        self.workerPreparer = workerPreparer
        self.skillCatalog = skillCatalog
        self.skillRootDirectory = skillRootDirectory
        self.readinessTimeout = readinessTimeout
        self.sleep = sleep
        self.skillSourceExists = skillSourceExists
        self.now = now
    }

    var hasActiveWork: Bool {
        state.tasks.contains { $0.status.isActiveForAgentQueuePreparation }
    }

    var canEditProfiles: Bool {
        !hasActiveWork && !isPreparationInProgress
    }

    func start() async {
        guard stateTask == nil else { return }
        let updates = await coordinator.stateUpdates()
        state = await coordinator.snapshot()
        effectExecutor.start()
        stateTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.state = snapshot
            }
        }
    }

    func stop() {
        stateTask?.cancel()
        stateTask = nil
        effectExecutor.stop()
        topologyReconciler?.stop()
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
        Task { try? await coordinator.pause(cause: "manual") }
    }

    func resume() {
        Task { try? await coordinator.resume() }
    }

    func removeRegistration(agentID: String) {
        Task {
            try? await coordinator.removeAgent(
                agentID: agentID,
                expectedBindingID: nil,
                cause: "manual"
            )
        }
    }

    func setExecutionMode(taskID: String, mode: AgentTaskExecutionMode) {
        Task {
            if let snapshot = try? await coordinator.setExecutionMode(taskID: taskID, mode: mode) {
                state = snapshot
            }
        }
    }

    func setWorkerCount(_ count: Int) {
        guard (1...4).contains(count),
              var preparation = state.preparation,
              count != preparation.configuration.workerCount,
              canEditProfiles,
              let configuration = try? preparation.configuration.replacingWorkerCount(count) else {
            return
        }
        preparation.configuration = configuration
        preparation.phase = .notPrepared
        preparation.completedWorkerCount = 0
        preparation.errorMessage = nil
        pendingRoleSkillChanges = []
        commitPreparation(preparation)
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
        guard canEditProfiles else { return }
        pendingRoleSkillChanges = []
        commitPreparation(
            AgentQueuePreparationState(
                configuration: configuration,
                phase: .notPrepared,
                completedWorkerCount: 0,
                errorMessage: nil
            )
        )
    }

    func skillOptions(query: String = "") async -> [AgentQueueSkillSelection] {
        guard let skillCatalog else { return [] }
        return await skillCatalog.options(rootDirectory: skillRootDirectory, query: query)
    }

    func prepareWorkers(allowSkillChanges: Bool) async {
        guard !hasActiveWork else { return }
        var snapshot = await coordinator.snapshot()
        var preparation = snapshot.preparation ?? AgentQueuePreparationState(
            configuration: .defaultConfiguration,
            phase: .notPrepared,
            completedWorkerCount: 0,
            errorMessage: nil
        )
        let configuration = preparation.configuration
        preparation.phase = .checkingSkills
        preparation.completedWorkerCount = 0
        preparation.errorMessage = nil
        snapshot = await commitPreparationNow(preparation) ?? snapshot

        do {
            let changes: [AgentQueueRoleSkillChange]
            do {
                changes = try await roleSkillInstaller?.pendingChanges() ?? []
            } catch {
                throw AgentQueuePreparationError.skillInstallationFailed(error.localizedDescription)
            }
            pendingRoleSkillChanges = changes
            if !changes.isEmpty && !allowSkillChanges {
                preparation.phase = .awaitingSkillConfirmation
                _ = await commitPreparationNow(preparation)
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
            preparation.desiredRoleSkillFingerprints = try await roleSkillFingerprints(
                preserving: preparation.desiredRoleSkillFingerprints
            )

            var missingSkillAgentIDs: Set<String> = []
            for agentID in configuration.activeAgentIDs {
                guard let profile = configuration.profile(id: agentID),
                      let missing = profile.additionalSkills.first(where: {
                          !skillSourceExists($0.sourcePath)
                      }) else { continue }
                missingSkillAgentIDs.insert(agentID)
                var record = preparation.record(agentID: agentID)
                    ?? preparationRecord(agentID: agentID, surfaceID: surfaceID(for: agentID, in: snapshot))
                record.phase = .failed
                record.errorMessage = missingSkillErrorMessage(path: missing.sourcePath)
                preparation = preparation.replacingRecord(record)
            }

            guard let workerPreparer else {
                throw AgentQueuePreparationError.plannerUnavailable
            }
            let plannerID = currentPlannerSurfaceID(in: snapshot)
            let topology = try await workerPreparer.prepareTopology(
                configuration: configuration,
                plannerSurfaceID: plannerID,
                existingWorkerSlots: snapshot.workers.map {
                    AgentQueueWorkerSlot(agentID: $0.id, surfaceID: $0.surfaceID)
                },
                activeWorkerAgentIDs: Set(snapshot.workers.compactMap {
                    $0.status.isActiveForAgentQueuePreparation ? $0.id : nil
                })
            )
            let workers = workerRoster(for: topology.workerSlots, preserving: snapshot.workers)
            snapshot = await commitPreparationNow(preparation, workers: workers) ?? snapshot

            let desiredWorkerIDs = Set(topology.workerSlots.map(\.agentID))
            for binding in snapshot.bindings where binding.role == .worker {
                let desiredSurface = topology.workerSlots.first(where: {
                    $0.agentID == binding.agentID
                })?.surfaceID
                if !desiredWorkerIDs.contains(binding.agentID) || desiredSurface != binding.surfaceID {
                    try? await coordinator.removeAgent(
                        agentID: binding.agentID,
                        expectedBindingID: binding.bindingID,
                        cause: "reprepare"
                    )
                }
            }
            snapshot = await coordinator.snapshot()

            let targetAgentIDs = configuration.activeAgentIDs.filter { agentID in
                !missingSkillAgentIDs.contains(agentID) && needsPreparation(
                    agentID: agentID,
                    preparation: preparation,
                    topology: topology,
                    snapshot: snapshot
                )
            }
            guard !targetAgentIDs.isEmpty else {
                finalizePreparation(&preparation, snapshot: snapshot)
                _ = await commitPreparationNow(preparation)
                topologyReconciler?.reconcile(cause: "preparation")
                return
            }

            let preparedAt = now()
            let newBindings = targetAgentIDs.compactMap { agentID -> AgentQueueAgentBinding? in
                guard let surfaceID = surfaceID(for: agentID, topology: topology) else { return nil }
                return AgentQueueAgentBinding(
                    bindingID: UUID().uuidString.lowercased(),
                    agentID: agentID,
                    role: agentID == AgentQueueAgentID.planner ? .planner : .worker,
                    workspaceID: snapshot.queue.workspaceID,
                    paneID: surfaceID,
                    surfaceID: surfaceID,
                    readiness: .pending,
                    preparedAt: preparedAt,
                    readyDeadline: preparedAt.addingTimeInterval(30),
                    readyAt: nil,
                    lastSeenAt: nil,
                    observedSessionID: nil
                )
            }
            guard newBindings.count == targetAgentIDs.count else {
                throw AgentQueuePreparationError.plannerUnavailable
            }
            for binding in newBindings {
                var record = preparation.record(agentID: binding.agentID)
                    ?? preparationRecord(agentID: binding.agentID, surfaceID: binding.surfaceID)
                record.surfaceID = binding.surfaceID
                record.phase = .preparing
                record.errorMessage = nil
                preparation = preparation.replacingRecord(record)
            }
            preparation.phase = targetAgentIDs.contains(AgentQueueAgentID.planner)
                ? .startingPlanner
                : .startingWorkers
            _ = await commitPreparationNow(preparation)
            try await coordinator.prepareBindings(newBindings)

            let bootstrapFailures = await workerPreparer.bootstrap(
                topology: topology,
                bindings: newBindings,
                configuration: configuration
            )
            var failureByAgent = Dictionary(
                uniqueKeysWithValues: bootstrapFailures.map { ($0.agentID, $0.message) }
            )
            let failedBootstrapIDs = Set(bootstrapFailures.map(\.agentID))
            for binding in newBindings where failedBootstrapIDs.contains(binding.agentID) {
                try? await coordinator.removeAgent(
                    agentID: binding.agentID,
                    expectedBindingID: binding.bindingID,
                    cause: "bootstrap_failed"
                )
            }

            for binding in newBindings where !failedBootstrapIDs.contains(binding.agentID) {
                guard let surfaceID = binding.surfaceID,
                      let sessionID = await paneAdapter.observedCodexSessionID(surfaceID: surfaceID) else {
                    continue
                }
                _ = try? await coordinator.recordObservedSession(
                    bindingID: binding.bindingID,
                    sessionID: sessionID
                )
            }

            let bindingsToAwait = newBindings.filter {
                !failedBootstrapIDs.contains($0.agentID)
            }
            let readinessResults = await withTaskGroup(
                of: (String, String, Bool).self,
                returning: [(String, String, Bool)].self
            ) { group in
                for binding in bindingsToAwait {
                    group.addTask { [coordinator, readinessTimeout, sleep] in
                        let ready = await Self.awaitReady(
                            bindingID: binding.bindingID,
                            coordinator: coordinator,
                            timeout: readinessTimeout,
                            sleep: sleep
                        )
                        return (binding.agentID, binding.bindingID, ready)
                    }
                }
                var values: [(String, String, Bool)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            for (agentID, bindingID, ready) in readinessResults where !ready {
                failureByAgent[agentID] = readyTimeoutMessage(agentID: agentID)
                try? await coordinator.removeAgent(
                    agentID: agentID,
                    expectedBindingID: bindingID,
                    cause: "ready_timeout"
                )
            }

            snapshot = await coordinator.snapshot()
            for binding in newBindings {
                var record = preparation.record(agentID: binding.agentID)
                    ?? preparationRecord(agentID: binding.agentID, surfaceID: binding.surfaceID)
                record.surfaceID = binding.surfaceID
                if let message = failureByAgent[binding.agentID] {
                    record.phase = .failed
                    record.errorMessage = message
                } else if snapshot.bindings.contains(where: {
                    $0.bindingID == binding.bindingID && $0.readiness == .ready
                }), let profile = configuration.profile(id: binding.agentID) {
                    record.appliedProfileFingerprint = AgentQueueProfileFingerprint.make(profile)
                    record.appliedRoleSkillFingerprint = roleFingerprint(
                        agentID: binding.agentID,
                        in: preparation.desiredRoleSkillFingerprints
                    )
                    record.phase = .ready
                    record.errorMessage = nil
                } else {
                    record.phase = .failed
                    record.errorMessage = readyTimeoutMessage(agentID: binding.agentID)
                }
                preparation = preparation.replacingRecord(record)
            }
            finalizePreparation(&preparation, snapshot: snapshot)
            _ = await commitPreparationNow(preparation)
            topologyReconciler?.reconcile(cause: "preparation")
        } catch {
            preparation.phase = .failed
            preparation.completedWorkerCount = 0
            preparation.errorMessage = preparationErrorMessage(error)
            _ = await commitPreparationNow(preparation)
        }
    }

    private func mutateProfile(
        agentID: String,
        transform: (AgentQueueAgentProfile) -> AgentQueueAgentProfile
    ) {
        guard canEditProfiles,
              var preparation = state.preparation,
              let profile = preparation.configuration.profile(id: agentID) else { return }
        let updated = transform(profile)
        guard updated != profile,
              let configuration = try? preparation.configuration.replacingProfile(updated) else {
            return
        }
        preparation.configuration = configuration
        preparation.phase = .notPrepared
        preparation.completedWorkerCount = 0
        preparation.errorMessage = nil
        var record = preparation.record(agentID: agentID)
            ?? preparationRecord(agentID: agentID, surfaceID: surfaceID(for: agentID, in: state))
        record.phase = .notPrepared
        record.errorMessage = nil
        preparation = preparation.replacingRecord(record)
        pendingRoleSkillChanges = []
        commitPreparation(preparation)
    }

    private func commitPreparation(_ preparation: AgentQueuePreparationState) {
        Task { _ = await commitPreparationNow(preparation) }
    }

    @discardableResult
    private func commitPreparationNow(
        _ preparation: AgentQueuePreparationState,
        workers: [AgentWorker]? = nil
    ) async -> AgentQueueState? {
        guard let snapshot = try? await coordinator.updatePreparation(
            preparation,
            workers: workers
        ) else { return nil }
        state = snapshot
        return snapshot
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

    private func needsPreparation(
        agentID: String,
        preparation: AgentQueuePreparationState,
        topology: AgentQueuePreparedTopology,
        snapshot: AgentQueueState
    ) -> Bool {
        guard preparation.isReady(agentID: agentID),
              let surfaceID = surfaceID(for: agentID, topology: topology),
              preparation.record(agentID: agentID)?.surfaceID == surfaceID,
              snapshot.bindings.contains(where: {
                  $0.agentID == agentID &&
                      $0.surfaceID == surfaceID &&
                      $0.readiness == .ready
              }) else {
            return true
        }
        return false
    }

    private func workerRoster(
        for slots: [AgentQueueWorkerSlot],
        preserving existing: [AgentWorker]
    ) -> [AgentWorker] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let workspaceID = state.queue.workspaceID
        let currentNow = now()
        return slots.map { slot in
            let index = AgentQueueAgentID.workerIDs.firstIndex(of: slot.agentID) ?? 0
            if var worker = existingByID[slot.agentID], worker.surfaceID == slot.surfaceID {
                worker.enabled = true
                worker.lastSeenAt = currentNow
                return worker
            }
            return AgentWorker(
                id: slot.agentID,
                workspaceID: workspaceID,
                paneID: slot.surfaceID,
                surfaceID: slot.surfaceID,
                label: Self.workerLabel(index: index),
                enabled: true,
                status: .offline,
                currentTaskID: nil,
                lastSeenAt: currentNow
            )
        }
    }

    private func finalizePreparation(
        _ preparation: inout AgentQueuePreparationState,
        snapshot: AgentQueueState
    ) {
        let activeRecords = preparation.configuration.activeAgentIDs.compactMap {
            preparation.record(agentID: $0)
        }
        let failures = activeRecords.filter { $0.phase == .failed }
        preparation.completedWorkerCount = AgentQueueAgentID.workerIDs
            .prefix(preparation.configuration.workerCount)
            .filter { agentID in
                preparation.isReady(agentID: agentID) && snapshot.bindings.contains(where: {
                    $0.agentID == agentID && $0.readiness == .ready
                })
            }
            .count
        if !failures.isEmpty {
            preparation.phase = .failed
            preparation.errorMessage = failures.compactMap(\.errorMessage).joined(separator: "\n")
        } else if preparation.configuration.activeAgentIDs.allSatisfy({ agentID in
            preparation.isReady(agentID: agentID) && snapshot.bindings.contains(where: {
                $0.agentID == agentID && $0.readiness == .ready
            })
        }) {
            preparation.phase = .ready
            preparation.errorMessage = nil
        } else {
            preparation.phase = .notPrepared
            preparation.errorMessage = nil
        }
    }

    private func currentPlannerSurfaceID(in snapshot: AgentQueueState) -> UUID {
        snapshot.bindings.first(where: { $0.role == .planner })?.surfaceID ?? plannerSurfaceID
    }

    private func surfaceID(for agentID: String, topology: AgentQueuePreparedTopology) -> UUID? {
        agentID == AgentQueueAgentID.planner
            ? topology.plannerSurfaceID
            : topology.workerSlots.first(where: { $0.agentID == agentID })?.surfaceID
    }

    private func surfaceID(for agentID: String, in snapshot: AgentQueueState) -> UUID? {
        if agentID == AgentQueueAgentID.planner {
            return currentPlannerSurfaceID(in: snapshot)
        }
        return snapshot.workers.first(where: { $0.id == agentID })?.surfaceID
    }

    private func preparationRecord(
        agentID: String,
        surfaceID: UUID?
    ) -> AgentQueueAgentPreparationRecord {
        AgentQueueAgentPreparationRecord(
            agentID: agentID,
            surfaceID: surfaceID,
            appliedProfileFingerprint: nil,
            appliedRoleSkillFingerprint: nil,
            phase: .notPrepared,
            errorMessage: nil
        )
    }

    private func roleFingerprint(
        agentID: String,
        in fingerprints: [String: String]
    ) -> String? {
        fingerprints[
            agentID == AgentQueueAgentID.planner
                ? AgentQueueRoleSkill.planner.rawValue
                : AgentQueueRoleSkill.worker.rawValue
        ]
    }

    private static func awaitReady(
        bindingID: String,
        coordinator: AgentQueueCoordinator,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async -> Bool {
        if await coordinator.snapshot().bindings.contains(where: {
            $0.bindingID == bindingID && $0.readiness == .ready
        }) {
            return true
        }
        let updates = await coordinator.stateUpdates()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await snapshot in updates {
                    if snapshot.bindings.contains(where: {
                        $0.bindingID == bindingID && $0.readiness == .ready
                    }) {
                        return true
                    }
                    if !snapshot.bindings.contains(where: { $0.bindingID == bindingID }) {
                        return false
                    }
                }
                return false
            }
            group.addTask {
                do {
                    try await sleep(timeout)
                } catch {
                    return false
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private var isPreparationInProgress: Bool {
        guard let phase = state.preparation?.phase else { return false }
        return switch phase {
        case .checkingSkills,
             .awaitingSkillConfirmation,
             .startingPlanner,
             .startingWorkers,
             .applyingSkills,
             .waitingForIdle:
            true
        case .notPrepared, .ready, .failed:
            false
        }
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

    private func readyTimeoutMessage(agentID: String) -> String {
        String(
            format: String(
                localized: "agentQueue.preparation.error.readyTimeout",
                defaultValue: "Agent ready handshake timed out: %@"
            ),
            agentID
        )
    }

    private func preparationErrorMessage(_ error: Error) -> String {
        guard let error = error as? AgentQueuePreparationError else {
            return error.localizedDescription
        }
        switch error {
        case let .invalidWorkerCount(count):
            return String.localizedStringWithFormat(
                String(
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

    private static func workerLabel(index: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "agentQueue.worker.defaultLabelFormat", defaultValue: "Worker %d"),
            index + 1
        )
    }
}

private extension AgentTaskStatus {
    var isActiveForAgentQueuePreparation: Bool {
        switch self {
        case .dispatching, .dispatched, .awaitingReport, .retrying:
            true
        case .queued, .completed, .blocked, .failed, .cancelled:
            false
        }
    }
}

private extension AgentWorkerStatus {
    var isActiveForAgentQueuePreparation: Bool {
        switch self {
        case .assigned, .running, .awaitingReport, .recovering:
            true
        case .idle, .offline:
            false
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

    func restorePersistedControllers(_ candidates: [AgentQueueRestoreCandidate]) async {
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
            await registry.register(runtime.coordinator, workspaceID: candidate.workspace.id)
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
        let plannerSurfaceID = workspace.focusedPanelId ?? UUID()
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
            plannerSurfaceID: plannerSurfaceID,
            paneAdapter: paneAdapter,
            coordinator: coordinator,
            effectExecutor: effectExecutor,
            roleSkillInstaller: roleSkillInstaller,
            workerPreparer: AgentQueueWorkerPreparationService(
                workspace: workspace,
                tabManager: tabManager
            ),
            skillCatalog: skillCatalog,
            skillRootDirectory: workspace.currentDirectory
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
        return AgentQueueState(
            queue: AgentQueue(
                id: "queue-\(workspace.id.uuidString.lowercased())",
                workspaceID: workspace.id,
                status: .running,
                createdAt: currentNow,
                updatedAt: currentNow
            ),
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
