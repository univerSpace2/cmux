import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueueReportDetectorTests: XCTestCase {
    func testDetectsPlannerCompletedReport() {
        let planner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let text = """
        some earlier output
        완료 보고 [T-20260709-0004]: 작업 완료. 변경/생성: none. 검증: read-screen. 미실행: tests skipped. 주의: none.
        """

        let reports = AgentQueueReportDetector.detect(
            in: text,
            surfaceID: planner,
            plannerSurfaceID: planner,
            knownTaskIDs: ["T-20260709-0004"]
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].taskID, "T-20260709-0004")
        XCTAssertEqual(reports[0].kind, .completed)
        XCTAssertEqual(reports[0].location, .planner)
    }

    func testDetectsWrongPaneReport() {
        let planner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let worker = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let text = "완료 보고 [T-20260709-0004]: worker pane에 남긴 보고"

        let reports = AgentQueueReportDetector.detect(
            in: text,
            surfaceID: worker,
            plannerSurfaceID: planner,
            knownTaskIDs: ["T-20260709-0004"]
        )

        XCTAssertEqual(reports.first?.location, .wrongPane)
    }

    func testIgnoresReportWithoutTaskID() {
        let planner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let reports = AgentQueueReportDetector.detect(
            in: "완료 보고: task id 없음",
            surfaceID: planner,
            plannerSurfaceID: planner,
            knownTaskIDs: ["T-20260709-0004"]
        )

        XCTAssertTrue(reports.isEmpty)
    }

    func testClassifiesUnknownTaskIDAsUnmatched() {
        let planner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let reports = AgentQueueReportDetector.detect(
            in: "완료 보고 [T-20260709-9999]: queue에 없는 보고",
            surfaceID: planner,
            plannerSurfaceID: planner,
            knownTaskIDs: ["T-20260709-0004"]
        )

        XCTAssertEqual(reports.first?.kind, .unmatched)
    }
}
