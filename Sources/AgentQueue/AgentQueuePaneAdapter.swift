import CmuxAgentChat
import Foundation

enum AgentQueueCodexReadiness: Equatable, Sendable {
    case absent
    case starting
    case busy
    case idle
}

enum AgentQueueShellActivity: Equatable, Sendable {
    case unknown
    case promptIdle
    case commandRunning
}

enum AgentQueueObservedCodexState: Equatable, Sendable {
    case idle
    case working
    case needsInput
}

struct AgentQueueCodexReadinessClassifier: Sendable {
    func classify(
        observedState: AgentQueueObservedCodexState?,
        shellActivity: AgentQueueShellActivity
    ) -> AgentQueueCodexReadiness {
        switch observedState {
        case .idle:
            return .idle
        case .working, .needsInput:
            return .busy
        case nil:
            return shellActivity == .promptIdle ? .absent : .starting
        }
    }

}

struct AgentQueueSendResult: Equatable, Sendable {
    var surfaceID: UUID
    var queued: Bool
}

@MainActor
enum AgentQueuePromptSubmission {
    static func events(for text: String) -> [TextBoxSubmit.DispatchEvent] {
        [
            .pasteText(text),
            .namedKey(TextBoxTerminalKey.returnKey.rawValue),
        ]
    }
}

protocol AgentQueuePaneAdapting: AnyObject, Sendable {
    func submitText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult
    func submitShellCommand(_ command: String, to surfaceID: UUID) async throws -> AgentQueueSendResult
    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness
    func observedCodexSessionID(surfaceID: UUID) async -> String?
}

extension AgentQueuePaneAdapting {
    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        .absent
    }

    func observedCodexSessionID(surfaceID _: UUID) async -> String? {
        nil
    }
}

enum AgentQueuePaneAdapterError: LocalizedError, Equatable {
    case surfaceUnavailable(UUID)
    case surfaceNotTerminal(UUID)

    var errorDescription: String? {
        switch self {
        case .surfaceUnavailable(let id):
            return "Agent Queue surface unavailable: \(id.uuidString)"
        case .surfaceNotTerminal(let id):
            return "Agent Queue surface is not terminal: \(id.uuidString)"
        }
    }
}

@MainActor
final class AppAgentQueuePaneAdapter: AgentQueuePaneAdapting {
    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func submitText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }

        let completion = await TextBoxSubmit.sendEvents(
            AgentQueuePromptSubmission.events(for: text),
            via: terminalPanel.surface
        )
        guard completion.didSubmit else {
            throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
        }
        terminalPanel.surface.forceRefresh(reason: "agentQueue.submitText")
        return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }

    func submitShellCommand(
        _ command: String,
        to surfaceID: UUID
    ) async throws -> AgentQueueSendResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }

        let textQueued: Bool
        switch terminalPanel.sendInputResult(command) {
        case .sent:
            textQueued = false
        case .queued:
            textQueued = true
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
        }

        let enterQueued: Bool
        switch terminalPanel.sendNamedKeyResult(TextBoxTerminalKey.returnKey.rawValue) {
        case .sent:
            enterQueued = false
        case .queued:
            enterQueued = true
        case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
            throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
        }

        terminalPanel.surface.forceRefresh(reason: "agentQueue.submitShellCommand")
        return AgentQueueSendResult(
            surfaceID: surfaceID,
            queued: textQueued || enterQueued
        )
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else { return .absent }
        let shellActivity = shellActivity(for: terminalPanel)
        let classifier = AgentQueueCodexReadinessClassifier()
        if let record = await observedCodexRecord(surfaceID: surfaceID) {
                let observedState: AgentQueueObservedCodexState
                switch record.state {
                case .idle:
                    observedState = .idle
                case .working:
                    observedState = .working
                case .needsInput:
                    observedState = .needsInput
                case .ended:
                    return classifier.classify(
                        observedState: nil,
                        shellActivity: shellActivity
                    )
                }
                return classifier.classify(
                    observedState: observedState,
                    shellActivity: shellActivity
                )
        }

        return classifier.classify(
            observedState: nil,
            shellActivity: shellActivity
        )
    }

    func observedCodexSessionID(surfaceID: UUID) async -> String? {
        await observedCodexRecord(surfaceID: surfaceID)?.sessionID
    }

    private func observedCodexRecord(surfaceID: UUID) async -> AgentChatSessionRecord? {
        guard let service = TerminalController.shared.agentChatTranscriptService else {
            return nil
        }
        _ = await service.observeAgentProcessesForListing(
            surfaceIDs: [surfaceID],
            waitUpTo: .seconds(1)
        )
        return service.sessionRecords(workspaceID: nil).first(where: { record in
            record.agentKind == .codex &&
                record.state != .ended &&
                record.surfaceID.flatMap(UUID.init(uuidString:)) == surfaceID
        })
    }

    private func terminalPanel(surfaceID: UUID) -> TerminalPanel? {
        guard let tabManager else { return nil }
        for workspace in tabManager.tabs {
            if let panel = workspace.terminalPanel(for: surfaceID) {
                return panel
            }
        }
        return nil
    }

    private func shellActivity(for terminalPanel: TerminalPanel) -> AgentQueueShellActivity {
        switch terminalPanel.shellActivity.state {
        case .unknown:
            return .unknown
        case .promptIdle:
            return .promptIdle
        case .commandRunning:
            return .commandRunning
        }
    }
}
