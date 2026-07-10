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

enum AgentQueueCodexReadinessClassifier {
    static func classify(
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

struct AgentQueueSurfaceTextSnapshot: Equatable, Sendable {
    var surfaceID: UUID
    var text: String
    var capturedAt: Date
}

struct AgentQueueSendResult: Equatable, Sendable {
    var surfaceID: UUID
    var queued: Bool
}

protocol AgentQueuePaneAdapting: AnyObject, Sendable {
    func sendText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult
    func sendEnter(to surfaceID: UUID) async throws -> AgentQueueSendResult
    func readText(surfaceID: UUID, lines: Int) async throws -> AgentQueueSurfaceTextSnapshot
    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness
}

extension AgentQueuePaneAdapting {
    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        .absent
    }
}

enum AgentQueuePaneAdapterError: LocalizedError, Equatable {
    case surfaceUnavailable(UUID)
    case surfaceNotTerminal(UUID)
    case readUnavailable(UUID)

    var errorDescription: String? {
        switch self {
        case .surfaceUnavailable(let id):
            return "Agent Queue surface unavailable: \(id.uuidString)"
        case .surfaceNotTerminal(let id):
            return "Agent Queue surface is not terminal: \(id.uuidString)"
        case .readUnavailable(let id):
            return "Agent Queue surface text unavailable: \(id.uuidString)"
        }
    }
}

@MainActor
final class AppAgentQueuePaneAdapter: AgentQueuePaneAdapting {
    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func sendText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }

        switch terminalPanel.sendInputResult(text) {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "agentQueue.sendText")
            return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
        case .queued:
            return AgentQueueSendResult(surfaceID: surfaceID, queued: true)
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
        }
    }

    func sendEnter(to surfaceID: UUID) async throws -> AgentQueueSendResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }

        switch terminalPanel.sendNamedKeyResult("enter") {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "agentQueue.sendEnter")
            return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
        case .queued:
            return AgentQueueSendResult(surfaceID: surfaceID, queued: true)
        case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
            throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
        }
    }

    func readText(surfaceID: UUID, lines: Int) async throws -> AgentQueueSurfaceTextSnapshot {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else {
            throw AgentQueuePaneAdapterError.readUnavailable(surfaceID)
        }
        guard let rawSnapshot = TerminalController.shared.readTerminalTextRawSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: true
        ) else {
            throw AgentQueuePaneAdapterError.readUnavailable(surfaceID)
        }

        let payload = TerminalController.terminalTextPayload(
            from: rawSnapshot,
            includeScrollback: true,
            lineLimit: lines
        )
        switch payload {
        case .success(let value):
            return AgentQueueSurfaceTextSnapshot(surfaceID: surfaceID, text: value.text, capturedAt: Date())
        case .failure:
            throw AgentQueuePaneAdapterError.readUnavailable(surfaceID)
        }
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else { return .absent }
        if let service = TerminalController.shared.agentChatTranscriptService {
            _ = await service.observeAgentProcessesForListing(
                surfaceIDs: [surfaceID],
                waitUpTo: .seconds(1)
            )
            if let record = service.sessionRecords(workspaceID: nil).first(where: { record in
                record.agentKind == .codex &&
                    record.state != .ended &&
                    record.surfaceID.flatMap(UUID.init(uuidString:)) == surfaceID
            }) {
                let observedState: AgentQueueObservedCodexState
                switch record.state {
                case .idle:
                    observedState = .idle
                case .working:
                    observedState = .working
                case .needsInput:
                    observedState = .needsInput
                case .ended:
                    return AgentQueueCodexReadinessClassifier.classify(
                        observedState: nil,
                        shellActivity: shellActivity(for: terminalPanel)
                    )
                }
                return AgentQueueCodexReadinessClassifier.classify(
                    observedState: observedState,
                    shellActivity: shellActivity(for: terminalPanel)
                )
            }
        }

        return AgentQueueCodexReadinessClassifier.classify(
            observedState: nil,
            shellActivity: shellActivity(for: terminalPanel)
        )
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
