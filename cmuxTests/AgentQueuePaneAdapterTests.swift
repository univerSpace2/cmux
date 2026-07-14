import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueuePaneAdapterTests: XCTestCase {
    @MainActor
    func testPromptSubmissionPastesTextThenSubmitsReturn() {
        XCTAssertEqual(
            AgentQueuePromptSubmission.events(for: "Do the work"),
            [
                .pasteText("Do the work"),
                .namedKey(TextBoxTerminalKey.returnKey.rawValue),
            ]
        )
    }

    @MainActor
    func testPromptSubmissionRunnerAcceptsPasteBeforeReturn() {
#if DEBUG
        let surface = AgentQueuePromptSubmissionSurface()
        var completion: TextBoxSubmit.CompletionContext?

        TextBoxSubmit.debugRunDispatchEvents(
            AgentQueuePromptSubmission.events(for: "Do the work"),
            via: surface
        ) { completion = $0 }

        XCTAssertEqual(surface.events, ["text:Do the work", "key:return"])
        XCTAssertEqual(completion, .empty)
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testCodexReadinessClassificationUsesLiveStateThenShellActivity() {
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier().classify(
                observedState: .idle,
                shellActivity: .commandRunning
            ),
            .idle
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier().classify(
                observedState: .working,
                shellActivity: .promptIdle
            ),
            .busy
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier().classify(
                observedState: .needsInput,
                shellActivity: .promptIdle
            ),
            .busy
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier().classify(
                observedState: nil,
                shellActivity: .commandRunning
            ),
            .starting
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier().classify(
                observedState: nil,
                shellActivity: .promptIdle
            ),
            .absent
        )
    }

    func testPaneAdapterErrorsExposeSurfaceIDInDescriptions() {
        let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        XCTAssertEqual(
            AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID).errorDescription,
            "Agent Queue surface unavailable: \(surfaceID.uuidString)"
        )
        XCTAssertEqual(
            AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID).errorDescription,
            "Agent Queue surface is not terminal: \(surfaceID.uuidString)"
        )
    }

    func testSnapshotAndSendResultAreEquatable() {
        let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        XCTAssertEqual(
            AgentQueueSendResult(surfaceID: surfaceID, queued: false),
            AgentQueueSendResult(surfaceID: surfaceID, queued: false)
        )
    }
}

@MainActor
private final class AgentQueuePromptSubmissionSurface: TextBoxSubmitSurfaceControlling {
    var clipboardReadGeneration = 0
    var textBoxSubmitObservationWindow: NSWindow?
    var textBoxSubmitTerminalSurface: TerminalSurface? { nil }
    private(set) var events: [String] = []

    func visibleText() -> String? { nil }

    func sendKeyText(_ text: String) -> Bool {
        events.append("keyText:\(text)")
        return true
    }

    func sendText(_ text: String) -> Bool {
        events.append("text:\(text)")
        return true
    }

    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult {
        events.append("key:\(keyName)")
        return .sent
    }

    func performBindingAction(_ action: String) -> Bool {
        events.append("action:\(action)")
        return true
    }
}
