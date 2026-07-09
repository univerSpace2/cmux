import Foundation

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

    private func terminalPanel(surfaceID: UUID) -> TerminalPanel? {
        guard let tabManager else { return nil }
        for workspace in tabManager.tabs {
            if let panel = workspace.terminalPanel(for: surfaceID) {
                return panel
            }
        }
        return nil
    }
}
