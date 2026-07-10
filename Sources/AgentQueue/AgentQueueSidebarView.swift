import Foundation
import SwiftUI

struct AgentQueueSkillRowSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sourcePath: String

    init(selection: AgentQueueSkillSelection) {
        id = selection.sourcePath
        name = selection.name
        sourcePath = selection.sourcePath
    }

    var selection: AgentQueueSkillSelection {
        AgentQueueSkillSelection(name: name, sourcePath: sourcePath)
    }
}

struct AgentQueuePreparationSnapshot: Equatable, Sendable {
    let workerCount: Int
    let selectedSkillID: String?
    let additionalSkillText: String
    let phase: AgentQueuePreparationPhase
    let phaseText: String
    let progressText: String?
    let errorMessage: String?
    let showsRetry: Bool
    let isPreparing: Bool
    let isStartDisabled: Bool

    init(preparation: AgentQueuePreparationState?, canStart: Bool) {
        let preparation = preparation ?? AgentQueuePreparationState(
            configuration: .defaultConfiguration,
            phase: .notPrepared,
            completedWorkerCount: 0,
            errorMessage: nil
        )
        workerCount = preparation.configuration.workerCount
        selectedSkillID = preparation.configuration.additionalSkill?.id
        additionalSkillText = preparation.configuration.additionalSkill?.name
            ?? String(localized: "agentQueue.preparation.skill.none", defaultValue: "None")
        phase = preparation.phase
        phaseText = AgentQueueDisplayText.preparationPhase(preparation.phase)
        errorMessage = preparation.errorMessage
        showsRetry = preparation.phase == .failed
        isPreparing = preparation.phase.isInProgress
        isStartDisabled = !canStart

        switch preparation.phase {
        case .startingWorkers, .applyingSkills, .waitingForIdle:
            progressText = String.localizedStringWithFormat(
                String(
                    localized: "agentQueue.preparation.progressFormat",
                    defaultValue: "Workers %d/%d"
                ),
                preparation.completedWorkerCount,
                preparation.configuration.workerCount
            )
        case .notPrepared, .checkingSkills, .awaitingSkillConfirmation, .startingPlanner, .ready, .failed:
            progressText = nil
        }
    }
}

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
    @State private var skillQuery = ""
    @State private var skillRows: [AgentQueueSkillRowSnapshot] = []
    @State private var showingSkillConfirmation = false

    private var preparationSnapshot: AgentQueuePreparationSnapshot {
        AgentQueuePreparationSnapshot(
            preparation: controller.state.preparation,
            canStart: controller.canStart
        )
    }

    private var displayedSkillRows: [AgentQueueSkillRowSnapshot] {
        guard let selected = controller.state.preparation?.configuration.additionalSkill else {
            return skillRows
        }
        guard !skillRows.contains(where: { $0.id == selected.id }) else { return skillRows }
        return [AgentQueueSkillRowSnapshot(selection: selected)] + skillRows
    }

    private var skillConfirmationMessage: String {
        let roles = controller.pendingRoleSkillChanges
            .map { "$\($0.role.rawValue)" }
            .joined(separator: ", ")
        return String.localizedStringWithFormat(
            String(
                localized: "agentQueue.preparation.confirmation.body",
                defaultValue: "Install or update these Agent Queue role skills before preparing panes: %@"
            ),
            roles
        )
    }

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
                    preparationSection
                    inputSection
                    queueSection
                    workerSection
                    logSection
                }
                .padding(12)
            }
        }
        .accessibilityIdentifier("AgentQueueSidebar")
        .task(id: skillQuery) {
            if !skillQuery.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            let options = await controller.skillOptions(query: skillQuery)
            guard !Task.isCancelled else { return }
            skillRows = options.map(AgentQueueSkillRowSnapshot.init(selection:))
            if controller.state.preparation?.phase == .awaitingSkillConfirmation {
                showingSkillConfirmation = true
            }
        }
        .onChange(of: controller.state.preparation?.phase) { phase in
            if phase == .awaitingSkillConfirmation {
                showingSkillConfirmation = true
            }
        }
        .alert(
            String(
                localized: "agentQueue.preparation.confirmation.title",
                defaultValue: "Install Agent Queue role skills?"
            ),
            isPresented: $showingSkillConfirmation
        ) {
            Button(
                String(localized: "agentQueue.preparation.confirmation.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {}
            Button(
                String(localized: "agentQueue.preparation.confirmation.apply", defaultValue: "Install and Prepare")
            ) {
                Task { await controller.prepareWorkers(allowSkillChanges: true) }
            }
        } message: {
            Text(skillConfirmationMessage)
        }
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
            .disabled(
                controller.state.queue.status != .running && preparationSnapshot.isStartDisabled
            )
        }
        .padding(10)
    }

    private var preparationSection: some View {
        let snapshot = preparationSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.preparation.title", defaultValue: "Worker preparation"))
                .font(.subheadline.weight(.semibold))

            Stepper(value: workerCountBinding, in: 1...4) {
                HStack {
                    Text(String(localized: "agentQueue.preparation.workerCount", defaultValue: "Worker count"))
                    Spacer()
                    Text(snapshot.workerCount, format: .number)
                        .monospacedDigit()
                }
            }
            .disabled(snapshot.isPreparing)

            TextField(
                String(
                    localized: "agentQueue.preparation.skill.searchPlaceholder",
                    defaultValue: "Search additional skills"
                ),
                text: $skillQuery
            )
            .textFieldStyle(.roundedBorder)
            .disabled(snapshot.isPreparing)

            Menu {
                Button(String(localized: "agentQueue.preparation.skill.none", defaultValue: "None")) {
                    setAdditionalSkill(nil)
                }
                Divider()
                ForEach(displayedSkillRows) { row in
                    Button {
                        setAdditionalSkill(row.selection)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(row.sourcePath)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(String(localized: "agentQueue.preparation.additionalSkill", defaultValue: "Additional skill"))
                    Spacer()
                    Text(snapshot.additionalSkillText)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(snapshot.isPreparing)
            .accessibilityIdentifier("AgentQueue.additionalSkill")

            HStack(spacing: 8) {
                Button(
                    snapshot.showsRetry
                        ? String(localized: "agentQueue.preparation.retry", defaultValue: "Retry")
                        : String(localized: "agentQueue.preparation.prepare", defaultValue: "Prepare Workers")
                ) {
                    Task { await controller.prepareWorkers(allowSkillChanges: false) }
                }
                .disabled(snapshot.isPreparing)

                if snapshot.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(snapshot.phaseText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let progressText = snapshot.progressText {
                Text(progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let errorMessage = snapshot.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
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
        let snapshot = preparationSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.workers.title", defaultValue: "Workers"))
                .font(.subheadline.weight(.semibold))
            HStack {
                VStack(alignment: .leading) {
                    Text(String(localized: "agentQueue.preparation.planner", defaultValue: "Planner"))
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "agentQueue.worker.surfaceFormat", defaultValue: "surface:%@"),
                            String(controller.state.queue.plannerSurfaceID.uuidString.prefix(8))
                        )
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(snapshot.phaseText)
                    .font(.caption.weight(.semibold))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
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

    private var workerCountBinding: Binding<Int> {
        Binding(
            get: { preparationSnapshot.workerCount },
            set: setWorkerCount
        )
    }

    private func setWorkerCount(_ workerCount: Int) {
        let additionalSkill = controller.state.preparation?.configuration.additionalSkill
        guard let configuration = try? AgentQueuePreparationConfiguration(
            workerCount: workerCount,
            additionalSkill: additionalSkill
        ) else { return }
        controller.setPreparationConfiguration(configuration)
    }

    private func setAdditionalSkill(_ additionalSkill: AgentQueueSkillSelection?) {
        guard let configuration = try? AgentQueuePreparationConfiguration(
            workerCount: preparationSnapshot.workerCount,
            additionalSkill: additionalSkill
        ) else { return }
        controller.setPreparationConfiguration(configuration)
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
    static func preparationPhase(_ phase: AgentQueuePreparationPhase) -> String {
        switch phase {
        case .notPrepared:
            return String(localized: "agentQueue.preparation.phase.notPrepared", defaultValue: "Not prepared")
        case .checkingSkills:
            return String(localized: "agentQueue.preparation.phase.checkingSkills", defaultValue: "Checking role skills…")
        case .awaitingSkillConfirmation:
            return String(
                localized: "agentQueue.preparation.phase.awaitingSkillConfirmation",
                defaultValue: "Waiting for skill installation confirmation"
            )
        case .startingPlanner:
            return String(localized: "agentQueue.preparation.phase.startingPlanner", defaultValue: "Starting planner Codex…")
        case .startingWorkers:
            return String(localized: "agentQueue.preparation.phase.startingWorkers", defaultValue: "Starting worker Codex…")
        case .applyingSkills:
            return String(localized: "agentQueue.preparation.phase.applyingSkills", defaultValue: "Applying skills…")
        case .waitingForIdle:
            return String(localized: "agentQueue.preparation.phase.waitingForIdle", defaultValue: "Waiting for workers…")
        case .ready:
            return String(localized: "agentQueue.preparation.phase.ready", defaultValue: "Ready")
        case .failed:
            return String(localized: "agentQueue.preparation.phase.failed", defaultValue: "Preparation failed")
        }
    }

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

private extension AgentQueuePreparationPhase {
    var isInProgress: Bool {
        switch self {
        case .checkingSkills, .startingPlanner, .startingWorkers, .applyingSkills, .waitingForIdle:
            return true
        case .notPrepared, .awaitingSkillConfirmation, .ready, .failed:
            return false
        }
    }
}
