import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent Queue CLI instructions")
struct AgentQueueCLIInstructionBuilderTests {
    @Test
    func bootstrapSendsReadyBeforeRolePrompt() {
        let prompt = AgentQueueCLIInstructionBuilder().bootstrap(
            agentID: "worker-1",
            role: .worker,
            bindingID: "binding-1",
            profile: .worker(index: 1)
        )
        #expect(prompt.hasPrefix(
            "cmux agent-queue agent ready --agent worker-1 --role worker --binding binding-1\n"
        ))
    }

    @Test
    func workerPromptExportsIDsAndRequiresStableReportCLI() throws {
        let fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        let task = try #require(fixture.state.tasks.first)
        let prompt = AgentQueueCLIInstructionBuilder().workerInstruction(
            task: task,
            bindingID: "binding-worker-1",
            profile: .worker(index: 1)
        )

        #expect(prompt.contains("export AGENT_QUEUE_TASK_ID='\(task.id)'"))
        #expect(prompt.contains("export AGENT_QUEUE_BINDING_ID='binding-worker-1'"))
        #expect(prompt.contains("cmux agent-queue report"))
        #expect(prompt.contains("--task \"$AGENT_QUEUE_TASK_ID\""))
        #expect(prompt.contains("--binding \"$AGENT_QUEUE_BINDING_ID\""))
        #expect(prompt.contains("stable report_id"))
        #expect(prompt.contains("same report ID/body/status"))
    }

    @Test
    func recoveryKeepsBindingAndUsesReportProtocol() throws {
        let fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        let task = try #require(fixture.state.tasks.first)
        let prompt = AgentQueueCLIInstructionBuilder().recoveryInstruction(
            task: task,
            bindingID: "binding-worker-1",
            profile: .worker(index: 1)
        )
        #expect(prompt.contains("export AGENT_QUEUE_BINDING_ID='binding-worker-1'"))
        #expect(prompt.contains("cmux agent-queue report"))
    }

    @Test
    func promptsContainNoScreenProtocolOrPaneSend() throws {
        let fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        let task = try #require(fixture.state.tasks.first)
        let builder = AgentQueueCLIInstructionBuilder()
        let prompts = [
            builder.workerInstruction(
                task: task,
                bindingID: "binding-worker-1",
                profile: .worker(index: 1)
            ),
            builder.recoveryInstruction(
                task: task,
                bindingID: "binding-worker-1",
                profile: .worker(index: 1)
            ),
        ]
        for prompt in prompts {
            #expect(!prompt.contains("[AGENT_QUEUE_TASKS]"))
            #expect(!prompt.contains("[AGENT_QUEUE_REPORT]"))
            #expect(!prompt.contains("screen polling"))
            #expect(!prompt.contains("cmux send"))
        }
    }
}
