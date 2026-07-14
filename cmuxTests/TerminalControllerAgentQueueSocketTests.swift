import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TerminalController Agent Queue socket bridge", .serialized)
struct TerminalControllerAgentQueueSocketTests {
    private static let socketWorker = DispatchQueue(
        label: "TerminalControllerAgentQueueSocketTests.worker"
    )

    @Test
    @MainActor
    func lifecycleCommandsMutateCoordinatorWithoutChangingFocus() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = try #require(manager.tabs.first)
            let surfaceID = try #require(workspace.focusedPanelId)
            let paneID = workspace.bonsplitController.focusedPaneId?.id ?? UUID()
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            TerminalController.shared.setActiveTabManager(manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                manager.tabs.forEach { $0.teardownAllPanels() }
            }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "agent-queue-socket-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let coordinator = AgentQueueCoordinator(
                workspaceID: workspace.id,
                persistenceID: workspace.stableId,
                legacyWorkspaceID: nil,
                initialState: socketState(
                    workspaceID: workspace.id,
                    surfaceID: surfaceID,
                    paneID: paneID
                ),
                persistence: AgentQueueFilePersistence(rootDirectory: root)
            )
            let registry = TerminalController.shared.agentQueueCoordinatorRegistry
            await registry.register(coordinator, workspaceID: workspace.id)
            defer { Task { await registry.unregister(workspaceID: workspace.id) } }

            let focus = FocusSnapshot(manager: manager, workspace: workspace)
            let calls: [(String, [String: Any])] = [
                (
                    "agent_queue.agent.ready",
                    [
                        "agent_id": AgentQueueAgentID.planner,
                        "role": "planner",
                        "binding_id": "binding-planner-1",
                    ]
                ),
                (
                    "agent_queue.agent.ready",
                    [
                        "agent_id": "worker-1",
                        "role": "worker",
                        "binding_id": "binding-worker-1",
                    ]
                ),
                (
                    "agent_queue.task.enqueue",
                    [
                        "submission": [
                            "submission_id": "submission-special-1",
                            "tasks": [[
                                "title": "Parser \\ \"quotes\" 작업",
                                "body": "Quotes: \"double\"\\nPath: C:\\\\Users\\\\agent\\nUnicode: 작업 計画 🚀",
                                "execution_mode": "parallel",
                                "timeout_seconds": 1_800,
                                "retry_limit": 1,
                            ]],
                        ],
                    ]
                ),
            ]

            for (method, params) in calls {
                let envelope = try await send(
                    method: method,
                    workspaceID: workspace.id,
                    surfaceID: surfaceID,
                    params: params
                )
                #expect(envelope["ok"] as? Bool == true, "\(method): \(envelope)")
                #expect(FocusSnapshot(manager: manager, workspace: workspace) == focus)
            }

            let taskID = try #require(await coordinator.snapshot().tasks.first?.id)
            let report = try await send(
                method: "agent_queue.task.report",
                workspaceID: workspace.id,
                surfaceID: surfaceID,
                params: [
                    "task_id": taskID,
                    "report_id": "report-1",
                    "status": "completed",
                    "binding_id": "binding-worker-1",
                    "body": "done \\ \"quoted\" 작업",
                ]
            )
            #expect(report["ok"] as? Bool == true)

            for method in ["agent_queue.pause", "agent_queue.resume"] {
                let envelope = try await send(
                    method: method,
                    workspaceID: workspace.id,
                    surfaceID: surfaceID
                )
                #expect(envelope["ok"] as? Bool == true, "\(method): \(envelope)")
            }
            let remove = try await send(
                method: "agent_queue.agent.remove",
                workspaceID: workspace.id,
                surfaceID: surfaceID,
                params: ["agent_id": "worker-1", "binding_id": "binding-worker-1"]
            )
            #expect(remove["ok"] as? Bool == true)
            #expect(FocusSnapshot(manager: manager, workspace: workspace) == focus)

            let finalState = await coordinator.snapshot()
            #expect(finalState.tasks.first?.status == .completed)
            #expect(finalState.workers.isEmpty)
        }
    }

    @Test
    @MainActor
    func missingRegistryAndWrongCallerSurfaceAreRejected() async throws {
        let missingWorkspaceID = UUID()
        let missing = try await send(
            method: "agent_queue.task.list",
            workspaceID: missingWorkspaceID,
            surfaceID: UUID()
        )
        #expect(errorCode(missing) == "agent_queue_unavailable")

        let surfaceID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-queue-wrong-caller-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = AgentQueueCoordinator(
            workspaceID: missingWorkspaceID,
            persistenceID: UUID(),
            legacyWorkspaceID: nil,
            initialState: socketState(
                workspaceID: missingWorkspaceID,
                surfaceID: surfaceID,
                paneID: UUID()
            ),
            persistence: AgentQueueFilePersistence(rootDirectory: root)
        )
        let registry = TerminalController.shared.agentQueueCoordinatorRegistry
        await registry.register(coordinator, workspaceID: missingWorkspaceID)
        defer { Task { await registry.unregister(workspaceID: missingWorkspaceID) } }

        let wrongCaller = try await send(
            method: "agent_queue.task.list",
            workspaceID: missingWorkspaceID,
            surfaceID: UUID()
        )
        #expect(errorCode(wrongCaller) == "unauthorized")
    }

    @MainActor
    private func send(
        method: String,
        workspaceID: UUID,
        surfaceID: UUID,
        params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        var allParams = params
        allParams["workspace_id"] = workspaceID.uuidString
        allParams["surface_id"] = surfaceID.uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            "id": method,
            "method": method,
            "params": allParams,
        ])
        let line = try #require(String(data: data, encoding: .utf8))
        let controller = TerminalController.shared
        let raw = await withCheckedContinuation { continuation in
            Self.socketWorker.async {
                continuation.resume(returning: controller.handleSocketLine(line))
            }
        }
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
    }

    private func errorCode(_ envelope: [String: Any]) -> String? {
        (envelope["error"] as? [String: Any])?["code"] as? String
    }

    private func socketState(
        workspaceID: UUID,
        surfaceID: UUID,
        paneID: UUID
    ) -> AgentQueueState {
        let now = Date(timeIntervalSince1970: 1_784_006_400)
        let planner = AgentQueueAgentBinding(
            bindingID: "binding-planner-1",
            agentID: AgentQueueAgentID.planner,
            role: .planner,
            workspaceID: workspaceID,
            paneID: paneID,
            surfaceID: surfaceID,
            readiness: .pending,
            preparedAt: now,
            readyDeadline: now.addingTimeInterval(30),
            readyAt: nil,
            lastSeenAt: nil,
            observedSessionID: nil
        )
        let workerBinding = AgentQueueAgentBinding(
            bindingID: "binding-worker-1",
            agentID: "worker-1",
            role: .worker,
            workspaceID: workspaceID,
            paneID: paneID,
            surfaceID: surfaceID,
            readiness: .pending,
            preparedAt: now,
            readyDeadline: now.addingTimeInterval(30),
            readyAt: nil,
            lastSeenAt: nil,
            observedSessionID: nil
        )
        return AgentQueueState(
            queue: AgentQueue(
                id: "queue-\(workspaceID.uuidString.lowercased())",
                workspaceID: workspaceID,
                plannerSurfaceID: surfaceID,
                status: .running,
                createdAt: now,
                updatedAt: now
            ),
            tasks: [],
            workers: [
                AgentWorker(
                    id: "worker-1",
                    workspaceID: workspaceID,
                    paneID: paneID,
                    surfaceID: surfaceID,
                    label: "Worker 1",
                    enabled: true,
                    status: .offline,
                    currentTaskID: nil,
                    lastSeenAt: nil,
                    bindingID: "binding-worker-1"
                ),
            ],
            bindings: [planner, workerBinding],
            events: []
        )
    }
}

private struct FocusSnapshot: Equatable {
    let workspaceID: UUID?
    let paneID: UUID?
    let surfaceID: UUID?

    @MainActor
    init(manager: TabManager, workspace: Workspace) {
        workspaceID = manager.selectedWorkspace?.id
        paneID = workspace.bonsplitController.focusedPaneId?.id
        surfaceID = workspace.focusedPanelId
    }
}
