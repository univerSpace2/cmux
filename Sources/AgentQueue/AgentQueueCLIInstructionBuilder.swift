import Foundation

struct AgentQueueCLIInstructionBuilder: Sendable {
    func bootstrap(
        agentID: String,
        role: AgentQueueAgentRole,
        bindingID: String,
        profile: AgentQueueAgentProfile
    ) -> String {
        let ready = "cmux agent-queue agent ready --agent \(agentID) --role \(role.rawValue) " +
            "--binding \(bindingID)"
        let skillRole: AgentQueueRoleSkill = role == .planner ? .planner : .worker
        return "\(ready)\n\(AgentQueueSkillPromptBuilder.prompt(role: skillRole, profile: profile))"
    }

    func launchCommand(agentID: String, bindingID: String) -> String {
        let escapedAgentID = shellSingleQuoted(agentID)
        let escapedBindingID = shellSingleQuoted(bindingID)
        return """
        cli="${CMUX_BUNDLED_CLI_PATH:-cmux}"
        codex
        status=$?
        "$cli" agent-queue agent offline --agent \(escapedAgentID) --binding \(escapedBindingID) >/dev/null 2>&1 || true
        exit "$status"
        """
    }

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

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
