import Foundation
import SwiftUI

private struct AgentQueueTaskRowSnapshot: Identifiable, Equatable {
    var id: String
    var title: String
    var status: AgentTaskStatus
    var statusText: String
    var executionModeText: String
    var isParallelAllowed: Bool
    var workerLabel: String
    var retryText: String
}

private struct AgentQueueWorkerRowSnapshot: Identifiable, Equatable {
    var id: String
    var label: String
    var statusText: String
    var surfaceText: String
    var enabled: Bool
}

private struct AgentQueueLogRowSnapshot: Identifiable, Equatable {
    var id: String
    var message: String
    var createdAt: Date
}

struct AgentQueueSidebarView: View {
    @ObservedObject var controller: AgentQueueController
    @State private var taskInput = ""

    private var taskRows: [AgentQueueTaskRowSnapshot] {
        let workersBySurface = Dictionary(uniqueKeysWithValues: controller.state.workers.map { ($0.surfaceID, $0.label) })
        return controller.state.tasks.map { task in
            AgentQueueTaskRowSnapshot(
                id: task.id,
                title: task.title,
                status: task.status,
                statusText: AgentQueueDisplayText.taskStatus(task.status),
                executionModeText: AgentQueueDisplayText.executionMode(task.executionMode),
                isParallelAllowed: task.executionMode == .parallelAllowed,
                workerLabel: task.assignedWorkerSurfaceID.flatMap { workersBySurface[$0] }
                    ?? String(localized: "agentQueue.task.unassignedWorker", defaultValue: "-"),
                retryText: "\(task.recoveryAttemptCount)/\(task.retryLimit)"
            )
        }
    }

    private var workerRows: [AgentQueueWorkerRowSnapshot] {
        controller.state.workers.map { worker in
            AgentQueueWorkerRowSnapshot(
                id: worker.id,
                label: worker.label,
                statusText: AgentQueueDisplayText.workerStatus(worker.status),
                surfaceText: String.localizedStringWithFormat(
                    String(localized: "agentQueue.worker.surfaceFormat", defaultValue: "surface:%@"),
                    String(worker.surfaceID.uuidString.prefix(8))
                ),
                enabled: worker.enabled
            )
        }
    }

    private var logRows: [AgentQueueLogRowSnapshot] {
        controller.state.events.suffix(80).map { event in
            AgentQueueLogRowSnapshot(id: event.id, message: event.message, createdAt: event.createdAt)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    inputSection
                    queueSection
                    workerSection
                    logSection
                }
                .padding(12)
            }
        }
        .accessibilityIdentifier("AgentQueueSidebar")
    }

    private var header: some View {
        HStack {
            Label(String(localized: "agentQueue.title", defaultValue: "Agent Queue"), systemImage: "list.bullet.rectangle")
                .font(.headline)
            Spacer()
            Button(
                controller.state.queue.status == .running
                    ? String(localized: "agentQueue.pause", defaultValue: "Pause")
                    : String(localized: "agentQueue.start", defaultValue: "Start")
            ) {
                if controller.state.queue.status == .running {
                    controller.pause()
                } else {
                    Task { await controller.start() }
                }
            }
        }
        .padding(10)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.input.title", defaultValue: "Task input"))
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $taskInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .accessibilityIdentifier("AgentQueue.taskInput")
            Button(String(localized: "agentQueue.input.addTasks", defaultValue: "Add Tasks")) {
                controller.createTasks(from: taskInput)
                taskInput = ""
            }
            .disabled(taskInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.queue.title", defaultValue: "Queue"))
                .font(.subheadline.weight(.semibold))
            LazyVStack(spacing: 6) {
                ForEach(taskRows) { row in
                    AgentQueueTaskRow(row: row) { enabled in
                        controller.setExecutionMode(
                            taskID: row.id,
                            mode: enabled ? .parallelAllowed : .sequential
                        )
                    }
                }
            }
        }
    }

    private var workerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.workers.title", defaultValue: "Workers"))
                .font(.subheadline.weight(.semibold))
            LazyVStack(spacing: 6) {
                ForEach(workerRows) { row in
                    AgentQueueWorkerRow(row: row)
                }
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.log.title", defaultValue: "Reliability Log"))
                .font(.subheadline.weight(.semibold))
            LazyVStack(spacing: 4) {
                ForEach(logRows) { row in
                    AgentQueueLogRow(row: row)
                }
            }
        }
    }
}

private struct AgentQueueTaskRow: View {
    let row: AgentQueueTaskRowSnapshot
    let onToggleParallel: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.id).font(.caption.monospaced())
                Spacer()
                Text(row.statusText).font(.caption.weight(.semibold))
            }
            Text(row.title).lineLimit(2)
            HStack {
                Text(row.executionModeText)
                Spacer()
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "agentQueue.task.workerFormat", defaultValue: "worker: %@"),
                        row.workerLabel
                    )
                )
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "agentQueue.task.retryLabelFormat", defaultValue: "retry: %@"),
                        row.retryText
                    )
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Toggle(
                String(localized: "agentQueue.task.parallelAllowed", defaultValue: "Parallel allowed"),
                isOn: Binding(
                    get: { row.isParallelAllowed },
                    set: onToggleParallel
                )
            )
            .disabled(row.status != .queued)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .accessibilityIdentifier("AgentQueue.task.\(row.id)")
    }
}

private struct AgentQueueWorkerRow: View {
    let row: AgentQueueWorkerRowSnapshot

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(row.label)
                Text(row.surfaceText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.statusText).font(.caption.weight(.semibold))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

private struct AgentQueueLogRow: View {
    let row: AgentQueueLogRowSnapshot

    var body: some View {
        Text(row.message)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
    }
}

private enum AgentQueueDisplayText {
    static func taskStatus(_ status: AgentTaskStatus) -> String {
        switch status {
        case .queued:
            return String(localized: "agentQueue.task.status.queued", defaultValue: "Queued")
        case .dispatching:
            return String(localized: "agentQueue.task.status.dispatching", defaultValue: "Dispatching")
        case .dispatched:
            return String(localized: "agentQueue.task.status.dispatched", defaultValue: "Dispatched")
        case .awaitingReport:
            return String(localized: "agentQueue.task.status.awaitingReport", defaultValue: "Awaiting report")
        case .retrying:
            return String(localized: "agentQueue.task.status.retrying", defaultValue: "Retrying")
        case .completed:
            return String(localized: "agentQueue.task.status.completed", defaultValue: "Completed")
        case .blocked:
            return String(localized: "agentQueue.task.status.blocked", defaultValue: "Blocked")
        case .failed:
            return String(localized: "agentQueue.task.status.failed", defaultValue: "Failed")
        case .cancelled:
            return String(localized: "agentQueue.task.status.cancelled", defaultValue: "Cancelled")
        }
    }

    static func workerStatus(_ status: AgentWorkerStatus) -> String {
        switch status {
        case .idle:
            return String(localized: "agentQueue.worker.status.idle", defaultValue: "Idle")
        case .assigned:
            return String(localized: "agentQueue.worker.status.assigned", defaultValue: "Assigned")
        case .running:
            return String(localized: "agentQueue.worker.status.running", defaultValue: "Running")
        case .awaitingReport:
            return String(localized: "agentQueue.worker.status.awaitingReport", defaultValue: "Awaiting report")
        case .recovering:
            return String(localized: "agentQueue.worker.status.recovering", defaultValue: "Recovering")
        case .offline:
            return String(localized: "agentQueue.worker.status.offline", defaultValue: "Offline")
        }
    }

    static func executionMode(_ mode: AgentTaskExecutionMode) -> String {
        switch mode {
        case .sequential:
            return String(localized: "agentQueue.task.executionMode.sequential", defaultValue: "Sequential")
        case .parallelAllowed:
            return String(localized: "agentQueue.task.executionMode.parallelAllowed", defaultValue: "Parallel allowed")
        }
    }
}
