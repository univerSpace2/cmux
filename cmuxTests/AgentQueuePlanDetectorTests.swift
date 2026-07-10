import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct AgentQueuePlanDetectorTests {
    private let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test func parsesMarkedPlannerPayloadAndTrimsTasks() throws {
        let text = """
        earlier output
        [AGENT_QUEUE_TASKS]
        {"request_id":"11111111-2222-3333-4444-555555555555","tasks":[
          {"title":" Inspect repo ","body":" Read files. "},
          {"title":"Implement","body":"Change code."}
        ]}
        [/AGENT_QUEUE_TASKS]
        later output
        """

        let detected = try #require(AgentQueuePlanDetector.detect(in: text)).get()

        #expect(detected == AgentQueuePlannedTasks(
            requestID: requestID,
            tasks: [
                AgentQueuePlannedTask(title: "Inspect repo", body: "Read files."),
                AgentQueuePlannedTask(title: "Implement", body: "Change code."),
            ]
        ))
    }

    @Test func parsesPlannerPayloadSplitByTerminalSoftWraps() throws {
        let text = """
        [AGENT_QUEUE_TASKS]
        {"request_id":"11111111-2222-3333-4444-
          555555555555","tasks":[{"title":"Runtime imported
          task","body":"No-op runtime verification task"}]}
        [/AGENT_QUEUE_TASKS]
        """

        let detected = try #require(AgentQueuePlanDetector.detect(in: text)).get()

        #expect(detected == AgentQueuePlannedTasks(
            requestID: requestID,
            tasks: [
                AgentQueuePlannedTask(
                    title: "Runtime imported task",
                    body: "No-op runtime verification task"
                ),
            ]
        ))
    }

    @Test func ignoresTextWithoutACompleteMarkerPair() {
        #expect(AgentQueuePlanDetector.detect(in: "noise only") == nil)
        #expect(AgentQueuePlanDetector.detect(in: "[AGENT_QUEUE_TASKS]\n{}") == nil)
    }

    @Test func usesTheNearestOpeningMarkerForTheLatestCompletedResponse() throws {
        let text = """
        echoed request
        [AGENT_QUEUE_TASKS]
        {"request_id":"11111111-2222-3333-4444-555555555555","tasks":[{"title":"example","body":"example"}]}
        planner response
        [AGENT_QUEUE_TASKS]
        {"request_id":"11111111-2222-3333-4444-555555555555","tasks":[{"title":"Real task","body":"Do real work"}]}
        [/AGENT_QUEUE_TASKS]
        """

        let detected = try #require(AgentQueuePlanDetector.detect(in: text)).get()

        #expect(detected.tasks == [
            AgentQueuePlannedTask(title: "Real task", body: "Do real work"),
        ])
    }

    @Test func rejectsMalformedJSON() throws {
        let result = try #require(AgentQueuePlanDetector.detect(in: """
        [AGENT_QUEUE_TASKS]
        {not json}
        [/AGENT_QUEUE_TASKS]
        """))

        #expect(throws: AgentQueuePlanDetectionError.malformedJSON) {
            try result.get()
        }
    }

    @Test func rejectsAnEmptyTaskList() throws {
        let result = try #require(AgentQueuePlanDetector.detect(in: """
        [AGENT_QUEUE_TASKS]
        {"request_id":"11111111-2222-3333-4444-555555555555","tasks":[]}
        [/AGENT_QUEUE_TASKS]
        """))

        #expect(throws: AgentQueuePlanDetectionError.emptyTasks) {
            try result.get()
        }
    }

    @Test(arguments: [
        "{\"title\":\"\",\"body\":\"Do work\"}",
        "{\"title\":\"Title\",\"body\":\"   \"}",
    ])
    func rejectsBlankTaskFields(taskJSON: String) throws {
        let result = try #require(AgentQueuePlanDetector.detect(in: """
        [AGENT_QUEUE_TASKS]
        {"request_id":"11111111-2222-3333-4444-555555555555","tasks":[\(taskJSON)]}
        [/AGENT_QUEUE_TASKS]
        """))

        #expect(throws: AgentQueuePlanDetectionError.invalidTask(index: 0)) {
            try result.get()
        }
    }
}
