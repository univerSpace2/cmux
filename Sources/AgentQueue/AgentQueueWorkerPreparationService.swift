import Foundation

struct AgentQueuePreparedWorkspace: Equatable, Sendable {
    var plannerSurfaceID: UUID
    var workerSurfaceIDs: [UUID]
    var workingDirectory: String
}

enum AgentQueueWorkerSplitDirection: Equatable, Sendable {
    case right
}

struct AgentQueueWorkerSplitRequest: Equatable, Sendable {
    var sourceSurfaceID: UUID
    var direction: AgentQueueWorkerSplitDirection
    var focus: Bool
    var workingDirectory: String
    var initialCommand: String
}

@MainActor
protocol AgentQueueWorkspaceDriving: AnyObject {
    var workingDirectory: String { get }

    func isTerminalSurface(_ surfaceID: UUID) -> Bool
    func shellActivity(surfaceID: UUID) -> AgentQueueShellActivity
    func createWorkerSplit(_ request: AgentQueueWorkerSplitRequest) -> UUID?
    func closeWorkerSurface(_ surfaceID: UUID) -> Bool
    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness
    func sendText(_ text: String, to surfaceID: UUID) async throws
    func sendEnter(to surfaceID: UUID) async throws
}

@MainActor
protocol AgentQueueWorkerPreparing: AnyObject {
    func prepare(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSurfaceIDs: [UUID],
        activeWorkerSurfaceIDs: Set<UUID>,
        progress: @escaping @MainActor (AgentQueuePreparationPhase, Int) -> Void
    ) async throws -> AgentQueuePreparedWorkspace
}

@MainActor
final class AgentQueueWorkerPreparationService: AgentQueueWorkerPreparing {
    private let driver: AgentQueueWorkspaceDriving
    private let readinessTimeout: Duration
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        driver: AgentQueueWorkspaceDriving,
        readinessTimeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(100),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.driver = driver
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    convenience init(workspace: Workspace, tabManager: TabManager) {
        self.init(driver: AppAgentQueueWorkspaceDriver(workspace: workspace, tabManager: tabManager))
    }

    func prepare(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSurfaceIDs: [UUID],
        activeWorkerSurfaceIDs: Set<UUID>,
        progress: @escaping @MainActor (AgentQueuePreparationPhase, Int) -> Void
    ) async throws -> AgentQueuePreparedWorkspace {
        let plan = try AgentQueueWorkerReconciler.plan(
            existingWorkerSurfaceIDs: existingWorkerSurfaceIDs,
            requestedCount: configuration.workerCount,
            activeWorkerSurfaceIDs: activeWorkerSurfaceIDs
        )
        guard driver.isTerminalSurface(plannerSurfaceID) else {
            throw AgentQueuePreparationError.plannerUnavailable
        }
        let workingDirectory = driver.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workingDirectory.isEmpty else {
            throw AgentQueuePreparationError.plannerUnavailable
        }

        progress(.startingPlanner, 0)
        try await preparePlanner(surfaceID: plannerSurfaceID)

        progress(.applyingSkills, 0)
        try await submit(AgentQueueSkillPromptBuilder.plannerPrompt, to: plannerSurfaceID)
        try await waitForIdle(surfaceID: plannerSurfaceID)

        progress(.startingWorkers, 0)
        for surfaceID in plan.close {
            guard driver.closeWorkerSurface(surfaceID) else {
                throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
            }
        }

        var workerSurfaceIDs = plan.keep
        var newlyCreatedSurfaceIDs: Set<UUID> = []
        for _ in 0..<plan.createCount {
            let request = AgentQueueWorkerSplitRequest(
                sourceSurfaceID: plannerSurfaceID,
                direction: .right,
                focus: false,
                workingDirectory: workingDirectory,
                initialCommand: "codex"
            )
            guard let surfaceID = driver.createWorkerSplit(request) else {
                throw AgentQueuePreparationError.plannerUnavailable
            }
            workerSurfaceIDs.append(surfaceID)
            newlyCreatedSurfaceIDs.insert(surfaceID)
        }

        for surfaceID in workerSurfaceIDs {
            try await prepareWorker(
                surfaceID: surfaceID,
                expectsInitialCommand: newlyCreatedSurfaceIDs.contains(surfaceID)
            )
        }

        progress(.applyingSkills, 0)
        let workerPrompt = AgentQueueSkillPromptBuilder.workerPrompt(
            additionalSkill: configuration.additionalSkill
        )
        for (index, surfaceID) in workerSurfaceIDs.enumerated() {
            try await submit(workerPrompt, to: surfaceID)
            progress(.waitingForIdle, index)
            try await waitForIdle(surfaceID: surfaceID)
            progress(.waitingForIdle, index + 1)
        }

        return AgentQueuePreparedWorkspace(
            plannerSurfaceID: plannerSurfaceID,
            workerSurfaceIDs: workerSurfaceIDs,
            workingDirectory: workingDirectory
        )
    }

    private func preparePlanner(surfaceID: UUID) async throws {
        switch await driver.codexReadiness(surfaceID: surfaceID) {
        case .idle:
            return
        case .busy:
            throw AgentQueuePreparationError.plannerBusy
        case .starting:
            try await waitForIdle(surfaceID: surfaceID)
        case .absent:
            guard driver.shellActivity(surfaceID: surfaceID) == .promptIdle else {
                throw AgentQueuePreparationError.plannerBusy
            }
            try await submit("codex", to: surfaceID)
            try await waitForIdle(surfaceID: surfaceID)
        }
    }

    private func prepareWorker(surfaceID: UUID, expectsInitialCommand: Bool) async throws {
        guard driver.isTerminalSurface(surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }
        if expectsInitialCommand {
            try await waitForIdle(surfaceID: surfaceID)
            return
        }
        switch await driver.codexReadiness(surfaceID: surfaceID) {
        case .idle:
            return
        case .busy, .starting:
            try await waitForIdle(surfaceID: surfaceID)
        case .absent:
            guard driver.shellActivity(surfaceID: surfaceID) == .promptIdle else {
                try await waitForIdle(surfaceID: surfaceID)
                return
            }
            try await submit("codex", to: surfaceID)
            try await waitForIdle(surfaceID: surfaceID)
        }
    }

    private func submit(_ text: String, to surfaceID: UUID) async throws {
        try await driver.sendText(text, to: surfaceID)
        try await driver.sendEnter(to: surfaceID)
    }

    private func waitForIdle(surfaceID: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)

        while clock.now <= deadline {
            if await driver.codexReadiness(surfaceID: surfaceID) == .idle {
                return
            }
            guard clock.now < deadline else { break }
            try await sleep(pollInterval)
        }
        throw AgentQueuePreparationError.codexReadinessTimedOut(surfaceID)
    }
}

@MainActor
final class AppAgentQueueWorkspaceDriver: AgentQueueWorkspaceDriving {
    private weak var workspace: Workspace?
    private weak var tabManager: TabManager?
    private let paneAdapter: AppAgentQueuePaneAdapter

    init(workspace: Workspace, tabManager: TabManager) {
        self.workspace = workspace
        self.tabManager = tabManager
        paneAdapter = AppAgentQueuePaneAdapter(tabManager: tabManager)
    }

    var workingDirectory: String {
        workspace?.currentDirectory ?? ""
    }

    func isTerminalSurface(_ surfaceID: UUID) -> Bool {
        workspace?.terminalPanel(for: surfaceID) != nil
    }

    func shellActivity(surfaceID: UUID) -> AgentQueueShellActivity {
        guard let state = workspace?.panelShellActivityStates[surfaceID] else { return .unknown }
        switch state {
        case .unknown:
            return .unknown
        case .promptIdle:
            return .promptIdle
        case .commandRunning:
            return .commandRunning
        }
    }

    func createWorkerSplit(_ request: AgentQueueWorkerSplitRequest) -> UUID? {
        guard request.direction == .right,
              let workspace,
              let tabManager else { return nil }
        return tabManager.newSplit(
            tabId: workspace.id,
            surfaceId: request.sourceSurfaceID,
            direction: .right,
            focus: request.focus,
            workingDirectory: request.workingDirectory,
            initialCommand: request.initialCommand
        )
    }

    func closeWorkerSurface(_ surfaceID: UUID) -> Bool {
        workspace?.closePanel(surfaceID, force: true) ?? false
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        await paneAdapter.codexReadiness(surfaceID: surfaceID)
    }

    func sendText(_ text: String, to surfaceID: UUID) async throws {
        _ = try await paneAdapter.sendText(text, to: surfaceID)
    }

    func sendEnter(to surfaceID: UUID) async throws {
        _ = try await paneAdapter.sendEnter(to: surfaceID)
    }
}
