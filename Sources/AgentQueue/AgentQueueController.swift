import Combine
import Foundation

@MainActor
final class AgentQueueController: ObservableObject {
    @Published private(set) var state: AgentQueueState

    private let paneAdapter: AgentQueuePaneAdapting
    private let store: AgentQueueStore?
    private let now: () -> Date
    private var nextSequence: Int

    init(
        initialState: AgentQueueState,
        paneAdapter: AgentQueuePaneAdapting,
        store: AgentQueueStore?,
        now: @escaping () -> Date = Date.init
    ) {
        state = initialState
        self.paneAdapter = paneAdapter
        self.store = store
        self.now = now
        nextSequence = initialState.tasks.count + 1
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

    func start() async {
        await apply(.queueStarted)
    }

    func pause() {
        Task { await apply(.queuePaused) }
    }

    func apply(_ event: AgentQueueInputEvent) async {
        let result = AgentQueueCore.reduce(state: state, event: event, now: now())
        state = result.state
        await runEffects(result.effects)
    }

    func pollReportsOnce(now pollTime: Date) async {
        let knownTaskIDs = Set(state.tasks.map(\.id))
        let surfaces = [state.queue.plannerSurfaceID] + state.workers.map(\.surfaceID)

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
                await apply(.reportDetected(report))
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

            case let .sendEnter(surfaceID):
                _ = try? await paneAdapter.sendEnter(to: surfaceID)

            case let .forwardReport(taskID, _, excerpt):
                let text = """
                자동 복구 보고 [\(taskID)]:
                Worker pane에서 완료 보고가 감지되어 planner pane으로 전달합니다.

                \(excerpt)

                """
                _ = try? await paneAdapter.sendText(text, to: state.queue.plannerSurfaceID)
                _ = try? await paneAdapter.sendEnter(to: state.queue.plannerSurfaceID)

            case let .sendCorrection(taskID, workerID):
                guard let worker = state.workers.first(where: { $0.id == workerID }) else { continue }
                let text = AgentQueueInstructionBuilder.correctionPrompt(
                    taskID: taskID,
                    plannerSurfaceID: state.queue.plannerSurfaceID
                )
                _ = try? await paneAdapter.sendText(text, to: worker.surfaceID)
                _ = try? await paneAdapter.sendEnter(to: worker.surfaceID)

            case let .sendRecovery(taskID, workerID):
                guard let task = state.tasks.first(where: { $0.id == taskID }),
                      let worker = state.workers.first(where: { $0.id == workerID }) else { continue }
                let text = AgentQueueInstructionBuilder.recoveryPrompt(
                    task: task,
                    plannerSurfaceID: state.queue.plannerSurfaceID
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
                plannerSurfaceID: state.queue.plannerSurfaceID,
                workerSurfaceID: worker.surfaceID
            )
        )
        if let result = try? await paneAdapter.sendText(text, to: worker.surfaceID) {
            await apply(.dispatchSucceeded(taskID: taskID, workerID: workerID, queued: result.queued))
        }
    }

    private func persistSoon() {
        guard let store else { return }
        let snapshot = state
        Task {
            try? await store.save(AgentQueueStore.pruneEvents(in: snapshot, limit: 500))
        }
    }

    private static func title(for body: String) -> String {
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= 80 { return collapsed }
        return "\(collapsed.prefix(80))…"
    }
}

@MainActor
final class AgentQueueControllerFactory {
    static let shared = AgentQueueControllerFactory()

    private var controllers: [UUID: AgentQueueController] = [:]
    private let store = AgentQueueStore()

    func controller(workspace: Workspace, tabManager: TabManager) -> AgentQueueController {
        if let existing = controllers[workspace.id] {
            return existing
        }

        let currentNow = Date()
        let plannerSurfaceID = workspace.focusedPanelId
            ?? workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
            ?? UUID()
        let queue = AgentQueue(
            id: "queue-\(workspace.id.uuidString.lowercased())",
            workspaceID: workspace.id,
            plannerSurfaceID: plannerSurfaceID,
            status: .paused,
            createdAt: currentNow,
            updatedAt: currentNow
        )
        let workers = workspace.panels.keys
            .filter { $0 != plannerSurfaceID }
            .sorted { $0.uuidString < $1.uuidString }
            .enumerated()
            .map { index, surfaceID in
                AgentWorker(
                    id: "worker-\(index + 1)",
                    workspaceID: workspace.id,
                    paneID: surfaceID,
                    surfaceID: surfaceID,
                    label: String.localizedStringWithFormat(
                        String(localized: "agentQueue.worker.defaultLabelFormat", defaultValue: "Worker %d"),
                        index + 1
                    ),
                    enabled: true,
                    status: .idle,
                    currentTaskID: nil,
                    lastSeenAt: currentNow
                )
            }

        let controller = AgentQueueController(
            initialState: AgentQueueState(queue: queue, tasks: [], workers: workers, events: []),
            paneAdapter: AppAgentQueuePaneAdapter(tabManager: tabManager),
            store: store
        )
        controllers[workspace.id] = controller
        return controller
    }
}
