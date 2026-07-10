import Foundation

struct AgentQueueInstructionContext: Equatable, Sendable {
    var task: AgentTask
    var workerSurfaceID: UUID
    var additionalSkill: AgentQueueSkillSelection?
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
        return "\(AgentQueueSkillPromptBuilder.workerPrompt(additionalSkill: context.additionalSkill))\n\(instruction)"
    }

    static func recoveryPrompt(task: AgentTask, additionalSkill: AgentQueueSkillSelection?) -> String {
        let instruction = String(
            format: String(
                localized: "agentQueue.instruction.recoveryCurrentPane",
                defaultValue: "복구 요청 [%@]:\n이 task의 완료 보고가 아직 감지되지 않았습니다.\n현재 대화에 아래 상태 중 하나를 즉시 출력하세요:\n- completed: 완료 보고 전문\n- blocked: 막힌 이유\n- running: 현재 진행 상황과 예상 남은 작업\n다른 pane으로 직접 전송하지 마세요.\n"
            ),
            task.id
        )
        return "\(AgentQueueSkillPromptBuilder.workerPrompt(additionalSkill: additionalSkill))\n\(instruction)"
    }
}
