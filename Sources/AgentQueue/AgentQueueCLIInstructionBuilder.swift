import Foundation

struct AgentQueueCLIInstructionBuilder: Sendable {
    func workerInstruction(
        task: AgentTask,
        bindingID: String,
        profile: AgentQueueAgentProfile
    ) -> String {
        """
        $cmux-agent-queue-worker

        \(profile.rolePrompt)

        AGENT_QUEUE_TASK_ID=\(task.id)
        AGENT_QUEUE_BINDING_ID=\(bindingID)

        \(task.body)

        Report completion through `cmux agent-queue report` using this exact task and binding ID.
        """
    }

    func recoveryInstruction(
        task: AgentTask,
        bindingID: String,
        profile: AgentQueueAgentProfile
    ) -> String {
        """
        $cmux-agent-queue-worker

        \(profile.rolePrompt)

        Recover the existing task without changing its assignment.
        AGENT_QUEUE_TASK_ID=\(task.id)
        AGENT_QUEUE_BINDING_ID=\(bindingID)

        Report the new outcome through `cmux agent-queue report`.
        """
    }
}
