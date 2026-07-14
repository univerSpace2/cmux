import AppKit
import Foundation

@MainActor
final class AgentQueueTopologyReconciler {
    private let workspaceID: UUID
    private let coordinator: AgentQueueCoordinator
    private let liveSurfaceIDs: @MainActor () -> Set<UUID>
    private let endedBindingIDs: @MainActor () -> Set<String>
    private let clock: ContinuousClock
    private var tasks: [Task<Void, Never>] = []

    init(
        workspaceID: UUID,
        coordinator: AgentQueueCoordinator,
        liveSurfaceIDs: @escaping @MainActor () -> Set<UUID>,
        endedBindingIDs: @escaping @MainActor () -> Set<String>,
        clock: ContinuousClock = .init()
    ) {
        self.workspaceID = workspaceID
        self.coordinator = coordinator
        self.liveSurfaceIDs = liveSurfaceIDs
        self.endedBindingIDs = endedBindingIDs
        self.clock = clock
    }

    func start(
        surfaceEvents: AsyncStream<CmuxSurfaceClosedEvent>,
        processEvents: AsyncStream<AgentChatSessionRecord>
    ) {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            for await event in surfaceEvents {
                guard !Task.isCancelled, let self else { return }
                await self.handleSurfaceClosed(event)
            }
        })
        tasks.append(Task { [weak self] in
            for await record in processEvents {
                guard !Task.isCancelled, let self else { return }
                await self.handleProcessLifecycle(record)
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            ) {
                guard !Task.isCancelled, let self else { return }
                await self.reconcileNow(cause: "app_active")
            }
        })
        let clock = clock
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Injected, cancellable safety deadline repairs missed lifecycle events.
                    try await clock.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.reconcileNow(cause: "safety_tick")
            }
        })
        reconcile(cause: "start")
    }

    func handleSurfaceClosed(_ event: CmuxSurfaceClosedEvent) async {
        guard event.workspaceID == workspaceID else { return }
        let state = await coordinator.snapshot()
        guard let binding = state.bindings.first(where: { $0.surfaceID == event.surfaceID }) else {
            return
        }
        try? await coordinator.removeAgent(
            agentID: binding.agentID,
            expectedBindingID: binding.bindingID,
            cause: "surface_closed:\(event.origin)"
        )
    }

    func handleProcessLifecycle(_ record: AgentChatSessionRecord) async {
        guard record.state == .ended,
              record.workspaceID == workspaceID.uuidString else { return }
        let state = await coordinator.snapshot()
        guard let binding = state.bindings.first(where: {
            $0.observedSessionID == record.sessionID
        }) else { return }
        try? await coordinator.removeAgent(
            agentID: binding.agentID,
            expectedBindingID: binding.bindingID,
            cause: "process_ended"
        )
    }

    func reconcile(cause: String) {
        Task { [weak self] in
            await self?.reconcileNow(cause: cause)
        }
    }

    func reconcileNow(cause: String) async {
        try? await coordinator.reconcile(
            liveSurfaceIDs: liveSurfaceIDs(),
            endedBindingIDs: endedBindingIDs(),
            cause: cause
        )
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }
}
