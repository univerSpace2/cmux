import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent Queue sidebar projection")
struct AgentQueueSidebarProjectionTests {
    @Test
    func immediateQueueHasNoGoalOrStartAction() {
        let state = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1).state
        let projection = AgentQueueSidebarProjection(state: state)
        #expect(projection.showsGoalInput == false)
        #expect(projection.primaryAction == .pause)
        #expect(projection.agentRows.count == 2)
    }

    @Test
    func pausedQueueProjectsResumeAndRegistrationRemoval() {
        var state = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1).state
        state.queue.status = .paused
        let projection = AgentQueueSidebarProjection(state: state)
        #expect(projection.primaryAction == .resume)
        #expect(projection.agentRows.allSatisfy { $0.canRemoveRegistration })
        #expect(projection.agentRows.first(where: { $0.role == .planner })?.readiness == .ready)
    }

    @Test
    func missingPlannerBindingProjectsNotReady() {
        var state = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1).state
        state.bindings.removeAll(where: { $0.role == .planner })
        let projection = AgentQueueSidebarProjection(state: state)
        #expect(projection.agentRows.first(where: { $0.role == .planner })?.readiness == .notReady)
    }
}
