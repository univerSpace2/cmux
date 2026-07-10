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
        shellActivity: AgentQueueShellActivity,
        visibleText: String = "",
        visibleReadyFallbackAllowed: Bool = true
    ) -> AgentQueueCodexReadiness {
        switch observedState {
        case .idle:
            return .idle
        case .working, .needsInput:
            return .busy
        case nil:
            if visibleReadyFallbackAllowed,
               shellActivity == .commandRunning,
               visibleText.contains("OpenAI Codex"),
               visibleText.split(whereSeparator: \Character.isNewline).contains(where: { line in
                   line.contains("· Ready ·")
               }) {
                return .idle
            }
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
    private var visibleReadyFallbackBlockedSurfaceIDs: Set<UUID> = []

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func sendText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        guard let terminalPanel = terminalPanel(surfaceID: surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }

        let result: AgentQueueSendResult
        switch terminalPanel.sendInputResult(text) {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "agentQueue.sendText")
            result = AgentQueueSendResult(surfaceID: surfaceID, queued: false)
        case .queued:
            result = AgentQueueSendResult(surfaceID: surfaceID, queued: true)
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines) != "codex" {
            visibleReadyFallbackBlockedSurfaceIDs.insert(surfaceID)
        }
        return result
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
        let shellActivity = shellActivity(for: terminalPanel)
        let visibleText = visibleText(for: terminalPanel)
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
                visibleReadyFallbackBlockedSurfaceIDs.remove(surfaceID)
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
                        shellActivity: shellActivity,
                        visibleText: visibleText
                    )
                }
                return AgentQueueCodexReadinessClassifier.classify(
                    observedState: observedState,
                    shellActivity: shellActivity,
                    visibleText: visibleText
                )
            }
        }

        return AgentQueueCodexReadinessClassifier.classify(
            observedState: nil,
            shellActivity: shellActivity,
            visibleText: visibleText,
            visibleReadyFallbackAllowed: !visibleReadyFallbackBlockedSurfaceIDs.contains(surfaceID)
        )
    }

    private func visibleText(for terminalPanel: TerminalPanel) -> String {
        guard let rawSnapshot = TerminalController.shared.readTerminalTextRawSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: false
        ) else {
            return ""
        }
        guard case .success(let value) = TerminalController.terminalTextPayload(
            from: rawSnapshot,
            includeScrollback: false,
            lineLimit: 40
        ) else {
            return ""
        }
        return value.text
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
