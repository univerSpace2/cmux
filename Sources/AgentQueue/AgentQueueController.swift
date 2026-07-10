import Combine
import Foundation

@MainActor
final class AgentQueueController: ObservableObject {
    @Published private(set) var state: AgentQueueState

    private let paneAdapter: AgentQueuePaneAdapting
    private let store: AgentQueueStore?
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
        pollInterval: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        now: @escaping () -> Date = Date.init
    ) {
        state = initialState
        self.paneAdapter = paneAdapter
        self.store = store
        self.pollInterval = pollInterval
        self.sleep = sleep
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

    func setExecutionMode(taskID: String, mode: AgentTaskExecutionMode) {
        guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard state.tasks[index].status == .queued else { return }

        state.tasks[index].executionMode = mode
        persistSoon()
    }

    func start() async {
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
        controller.startMonitoring()
        controllers[workspace.id] = controller
        return controller
    }
}
