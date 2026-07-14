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

    func launchCommand(
        agentID: String,
        bindingID: String,
        initialPrompt: String? = nil
    ) -> String {
        let escapedAgentID = shellSingleQuoted(agentID)
        let escapedBindingID = shellSingleQuoted(bindingID)
        let codexCommand = if let initialPrompt {
            "codex \(shellSingleQuoted(initialPrompt))"
        } else {
            "codex"
        }
        return """
        cli="${CMUX_BUNDLED_CLI_PATH:-cmux}"
        \(codexCommand)
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
        let taskID = shellSingleQuoted(task.id)
        let bindingID = shellSingleQuoted(bindingID)
        return """
        $cmux-agent-queue-worker

        \(profile.rolePrompt)

        export AGENT_QUEUE_TASK_ID=\(taskID)
        export AGENT_QUEUE_BINDING_ID=\(bindingID)

        \(task.body)

        Create one stable report_id for this report attempt. Send the outcome with:
        printf '%s' "$report_body" | cmux agent-queue report \
          --task "$AGENT_QUEUE_TASK_ID" \
          --report "$report_id" \
          --status completed \
          --binding "$AGENT_QUEUE_BINDING_ID" \
          --stdin
        Use failed for recoverable execution failure, blocked when user or safety input is required.
        Terminal prose does not complete this task. After uncertain transport, retry the same report ID/body/status.
        """
    }

    func recoveryInstruction(
        task: AgentTask,
        bindingID: String,
        profile: AgentQueueAgentProfile
    ) -> String {
        let taskID = shellSingleQuoted(task.id)
        let bindingID = shellSingleQuoted(bindingID)
        return """
        $cmux-agent-queue-worker

        \(profile.rolePrompt)

        Recover the existing task without changing its assignment.
        export AGENT_QUEUE_TASK_ID=\(taskID)
        export AGENT_QUEUE_BINDING_ID=\(bindingID)

        Create one stable report_id for this report attempt. Report through `cmux agent-queue report`
        with the exact task and binding IDs. After uncertain transport, retry the same report ID/body/status.
        """
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
