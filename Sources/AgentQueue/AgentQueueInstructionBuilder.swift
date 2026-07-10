import Foundation

struct AgentQueueInstructionContext: Equatable, Sendable {
    var task: AgentTask
    var workerSurfaceID: UUID
    var profile: AgentQueueAgentProfile
}

enum AgentQueueInstructionBuilder {
    static func workerInstruction(context: AgentQueueInstructionContext) -> String {
        let instruction = String(
            format: String(
                localized: "agentQueue.instruction.workerCurrentPane",
                defaultValue: "작업지시: %@\n\n완료 후 반드시 아래 task_id를 포함한 완료 보고를 현재 대화에 직접 출력하세요.\nAgent Queue가 worker pane의 보고를 감지해 planner pane으로 자동 전달합니다.\n다른 pane으로 직접 전송하지 마세요.\n\n[AGENT_QUEUE_TASK]\ntask_id: %@\nworker_surface_id: surface:%@\nreport_target: current_pane\nreport_required: true\n[/AGENT_QUEUE_TASK]\n\n완료 보고 형식:\n완료 보고 [%@]: <요약>. 변경/생성: <paths or none>. 검증: <evidence>. 미실행: <reason>. 주의: <follow-up>.\n"
            ),
            context.task.body,
            context.task.id,
            context.workerSurfaceID.uuidString.lowercased(),
            context.task.id
        )
        return "\(AgentQueueSkillPromptBuilder.prompt(role: .worker, profile: context.profile))\n\(instruction)"
    }

    static func recoveryPrompt(task: AgentTask, profile: AgentQueueAgentProfile) -> String {
        let instruction = String(
            format: String(
                localized: "agentQueue.instruction.recoveryCurrentPane",
                defaultValue: "복구 요청 [%@]:\n이 task의 완료 보고가 아직 감지되지 않았습니다.\n현재 대화에 아래 상태 중 하나를 즉시 출력하세요:\n- completed: 완료 보고 전문\n- blocked: 막힌 이유\n- running: 현재 진행 상황과 예상 남은 작업\n다른 pane으로 직접 전송하지 마세요.\n"
            ),
            task.id
        )
        return "\(AgentQueueSkillPromptBuilder.prompt(role: .worker, profile: profile))\n\(instruction)"
    }

    static func plannerInstruction(
        _ instruction: String,
        profile: AgentQueueAgentProfile
    ) -> String {
        "\(AgentQueueSkillPromptBuilder.prompt(role: .planner, profile: profile))\n\(instruction)"
    }

    static func plannerRequest(
        goal: String,
        requestID: UUID,
        profile: AgentQueueAgentProfile
    ) -> String {
        let id = requestID.uuidString.lowercased()
        let instruction = """
        사용자 목표를 실행 가능한 작업으로 분해하세요.

        [AGENT_QUEUE_PLAN_REQUEST]
        request_id: \(id)
        goal:
        \(goal)
        [/AGENT_QUEUE_PLAN_REQUEST]

        설명이나 Markdown 코드 펜스 없이 다음 형식만 출력하세요.
        [AGENT_QUEUE_TASKS]
        {"request_id":"\(id)","tasks":[{"title":"작업 제목","body":"구체적인 작업 지시"}]}
        마지막 줄은 같은 이름 앞에 /를 붙인 종료 표식으로 닫으세요.
        """
        return plannerInstruction(instruction, profile: profile)
    }
}
