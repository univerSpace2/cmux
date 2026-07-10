import Foundation

enum AgentQueueStatus: String, Codable, Equatable, Sendable {
    case paused
    case running
}

enum AgentQueueDispatchFailureStage: String, Codable, Equatable, Sendable {
    case text
    case enter
}

enum AgentTaskStatus: String, Codable, Equatable, Sendable {
    case queued
    case dispatching
    case dispatched
    case awaitingReport = "awaiting_report"
    case retrying
    case completed
    case blocked
    case failed
    case cancelled
}

enum AgentTaskExecutionMode: String, Codable, Equatable, Sendable {
    case sequential
    case parallelAllowed = "parallel_allowed"
}

enum AgentWorkerStatus: String, Codable, Equatable, Sendable {
    case idle
    case assigned
    case running
    case awaitingReport = "awaiting_report"
    case recovering
    case offline
}

enum AgentQueueLogEventType: String, Codable, Equatable, Sendable {
    case taskCreated = "task_created"
    case queueStarted = "queue_started"
    case queuePaused = "queue_paused"
    case taskDispatched = "task_dispatched"
    case enterSubmitted = "enter_submitted"
    case reportDetected = "report_detected"
    case wrongPaneReportDetected = "wrong_pane_report_detected"
    case ignoredReport = "ignored_report"
    case reportForwarded = "report_forwarded"
    case timeout
    case recoverySent = "recovery_sent"
    case taskCompleted = "task_completed"
    case taskFailed = "task_failed"
    case taskCancelled = "task_cancelled"
}

struct AgentQueue: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var workspaceID: UUID
    var plannerSurfaceID: UUID
    var status: AgentQueueStatus
    var createdAt: Date
    var updatedAt: Date
}

struct AgentTask: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var queueID: String
    var title: String
    var body: String
    var status: AgentTaskStatus
    var executionMode: AgentTaskExecutionMode
    var assignedWorkerSurfaceID: UUID?
    var dispatchAttemptCount: Int
    var recoveryAttemptCount: Int
    var timeoutSeconds: TimeInterval
    var retryLimit: Int
    var createdAt: Date
    var dispatchedAt: Date?
    var completedAt: Date?
    var lastError: String?
}

struct AgentWorker: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var workspaceID: UUID
    var paneID: UUID
    var surfaceID: UUID
    var label: String
    var enabled: Bool
    var status: AgentWorkerStatus
    var currentTaskID: String?
    var lastSeenAt: Date?
}

struct AgentQueueLogEvidence: Codable, Equatable, Sendable {
    var workspaceID: UUID?
    var paneID: UUID?
    var surfaceID: UUID?
    var command: String?
    var screenExcerpt: String?
}

struct AgentQueueLogEvent: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var queueID: String
    var taskID: String?
    var workerID: String?
    var type: AgentQueueLogEventType
    var message: String
    var evidence: AgentQueueLogEvidence?
    var createdAt: Date
}

struct AgentQueueState: Codable, Equatable, Sendable {
    var queue: AgentQueue
    var tasks: [AgentTask]
    var workers: [AgentWorker]
    var events: [AgentQueueLogEvent]
    var preparation: AgentQueuePreparationState? = nil
}

enum AgentTaskIDFactory {
    static func makeTaskID(now: Date, sequence: Int, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "T-%04d%02d%02d-%04d", year, month, day, sequence)
    }
}

enum AgentTaskSplitter {
    static func split(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var chunks: [String] = []
        var current: [String] = []
        var blankLineCount = 0

        func flush() {
            let body = current
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                chunks.append(body)
            }
            current.removeAll(keepingCapacity: true)
            blankLineCount = 0
        }

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                flush()
                continue
            }
            if trimmed.isEmpty {
                blankLineCount += 1
                if blankLineCount >= 2 {
                    flush()
                } else if !current.isEmpty {
                    current.append("")
                }
                continue
            }
            blankLineCount = 0
            current.append(line)
        }
        flush()
        return chunks
    }
}

extension JSONEncoder {
    static var agentQueue: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var agentQueue: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
