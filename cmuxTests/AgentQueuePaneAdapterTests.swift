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
            AgentQueueCodexReadinessClassifier.classify(
                observedState: .idle,
                shellActivity: .commandRunning
            ),
            .idle
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: .working,
                shellActivity: .promptIdle
            ),
            .busy
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: .needsInput,
                shellActivity: .promptIdle
            ),
            .busy
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: nil,
                shellActivity: .commandRunning
            ),
            .starting
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: nil,
                shellActivity: .promptIdle
            ),
            .absent
        )
    }

    func testCodexReadinessUsesVisibleReadyScreenBeforeTranscriptExists() {
        let readyScreen = """
        ╭─────────────────────────────────────────────────╮
        │ >_ OpenAI Codex (v0.144.1)                      │
        ╰─────────────────────────────────────────────────╯
        › Explain this codebase
        gpt-5.6-sol xhigh · ~/coding-universe/zmux/cmux · Ready · Workspace · Approve for me
        """

        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: nil,
                shellActivity: .commandRunning,
                visibleText: readyScreen
            ),
            .idle
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: nil,
                shellActivity: .commandRunning,
                visibleText: "OpenAI Codex\nWorking (12s • esc to interrupt)"
            ),
            .starting
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: nil,
                shellActivity: .promptIdle,
                visibleText: readyScreen
            ),
            .absent
        )
    }

    func testCodexReadinessCanIgnoreStaleVisibleReadyScreenAfterSubmission() {
        let readyScreen = """
        ╭─────────────────────────────────────────────────╮
        │ >_ OpenAI Codex (v0.144.1)                      │
        ╰─────────────────────────────────────────────────╯
        › Explain this codebase
        gpt-5.6-sol xhigh · ~/coding-universe/zmux/cmux · Ready · Workspace · Approve for me
        """

        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: nil,
                shellActivity: .commandRunning,
                visibleText: readyScreen,
                visibleReadyFallbackAllowed: false
            ),
            .starting
        )
    }

    func testCodexReadinessCanIgnoreStaleObservedIdleUntilSubmittedPromptStarts() {
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: .idle,
                shellActivity: .commandRunning,
                observedIdleAllowed: false
            ),
            .starting
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: .working,
                shellActivity: .commandRunning,
                observedIdleAllowed: false
            ),
            .busy
        )
        XCTAssertEqual(
            AgentQueueCodexReadinessClassifier.classify(
                observedState: .idle,
                shellActivity: .commandRunning,
                observedIdleAllowed: true
            ),
            .idle
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
        XCTAssertEqual(
            AgentQueuePaneAdapterError.readUnavailable(surfaceID).errorDescription,
            "Agent Queue surface text unavailable: \(surfaceID.uuidString)"
        )
    }

    func testSnapshotAndSendResultAreEquatable() {
        let surfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let now = Date(timeIntervalSince1970: 1_782_998_400)

        XCTAssertEqual(
            AgentQueueSurfaceTextSnapshot(surfaceID: surfaceID, text: "output", capturedAt: now),
            AgentQueueSurfaceTextSnapshot(surfaceID: surfaceID, text: "output", capturedAt: now)
        )
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
