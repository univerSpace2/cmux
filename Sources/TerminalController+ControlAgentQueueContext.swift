import CmuxControlSocket

extension TerminalController: ControlAgentQueueContext {
    nonisolated func controlAgentQueue(
        _ call: ControlAgentQueueCall
    ) async -> ControlCallResult {
        guard let coordinator = await agentQueueCoordinatorRegistry.coordinator(
            workspaceID: call.workspaceID
        ) else {
            return .err(
                code: "agent_queue_unavailable",
                message: "Agent Queue is not initialized for this workspace.",
                data: nil
            )
        }
        return await AgentQueueControlCallAdapter.handle(call, coordinator: coordinator)
    }
}
