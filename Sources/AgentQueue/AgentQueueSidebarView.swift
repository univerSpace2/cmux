import Foundation
import SwiftUI

enum AgentQueueSidebarPrimaryAction: Equatable {
    case pause
    case resume
}

struct AgentQueueAgentRowSnapshot: Identifiable, Equatable {
    let id: String
    let role: AgentQueueAgentRole
    let readiness: AgentQueueAgentReadiness
    let surfaceLabel: String?
    let taskTitle: String?
    let canRemoveRegistration: Bool
}

struct AgentQueueAgentRowActions {
    let removeRegistration: () -> Void
    let reprepare: () -> Void
}

struct AgentQueueSidebarProjection {
    let showsGoalInput = false
    let primaryAction: AgentQueueSidebarPrimaryAction
    let agentRows: [AgentQueueAgentRowSnapshot]

    init(state: AgentQueueState) {
        primaryAction = state.queue.status == .running ? .pause : .resume
        let plannerBinding = state.bindings.first(where: { $0.role == .planner })
        let planner = AgentQueueAgentRowSnapshot(
            id: AgentQueueAgentID.planner,
            role: .planner,
            readiness: plannerBinding?.readiness ?? .notReady,
            surfaceLabel: plannerBinding?.surfaceID.map { String($0.uuidString.prefix(8)) },
            taskTitle: nil,
            canRemoveRegistration: plannerBinding != nil
        )
        let workers = state.workers.map { worker in
            let binding = state.bindings.first(where: { $0.agentID == worker.id })
            return AgentQueueAgentRowSnapshot(
                id: worker.id,
                role: .worker,
                readiness: binding?.readiness ?? .notReady,
                surfaceLabel: binding?.surfaceID.map { String($0.uuidString.prefix(8)) },
                taskTitle: worker.currentTaskID.flatMap { taskID in
                    state.tasks.first(where: { $0.id == taskID })?.title
                },
                canRemoveRegistration: binding != nil
            )
        }
        agentRows = [planner] + workers
    }
}

struct AgentQueuePreparationSnapshot: Equatable, Sendable {
    let workerCount: Int
    let profiles: [AgentQueueAgentProfileSnapshot]
    let phase: AgentQueuePreparationPhase
    let phaseText: String
    let progressText: String?
    let errorMessage: String?
    let showsRetry: Bool
    let isPreparing: Bool
    let isWorkerCountDecreaseDisabled: Bool
    let isWorkerCountIncreaseDisabled: Bool

    init(
        preparation: AgentQueuePreparationState?,
        canEditProfiles: Bool = true,
        hasActiveWork: Bool = false
    ) {
        let preparation = preparation ?? AgentQueuePreparationState(
            configuration: .defaultConfiguration,
            phase: .notPrepared,
            completedWorkerCount: 0,
            errorMessage: nil
        )
        workerCount = preparation.configuration.workerCount
        profiles = preparation.configuration.activeAgentIDs.compactMap { agentID in
            guard let profile = preparation.configuration.profile(id: agentID) else { return nil }
            return AgentQueueAgentProfileSnapshot(
                profile: profile,
                record: preparation.record(agentID: agentID),
                isEditingDisabled: !canEditProfiles,
                isReady: preparation.isReady(agentID: agentID)
            )
        }
        phase = preparation.phase
        phaseText = AgentQueueDisplayText.preparationPhase(preparation.phase)
        errorMessage = preparation.errorMessage
        showsRetry = preparation.phase == .failed
        isPreparing = preparation.phase.isInProgress
        isWorkerCountDecreaseDisabled = isPreparing || hasActiveWork || workerCount <= 1
        isWorkerCountIncreaseDisabled = isPreparing || workerCount >= 4

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
    @Bindable var controller: AgentQueueController
    @State private var skillQuery = ""
    @State private var skillRows: [AgentQueueSkillRowSnapshot] = []
    @State private var showingSkillConfirmation = false

    private var preparationSnapshot: AgentQueuePreparationSnapshot {
        AgentQueuePreparationSnapshot(
            preparation: controller.state.preparation,
            canEditProfiles: controller.canEditProfiles,
            hasActiveWork: controller.hasActiveWork
        )
    }

    private var sidebarProjection: AgentQueueSidebarProjection {
        AgentQueueSidebarProjection(state: controller.state)
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
        .onChange(of: controller.state.preparation?.phase) { _, phase in
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
                sidebarProjection.primaryAction == .pause
                    ? String(localized: "agentQueue.pause", defaultValue: "Pause")
                    : String(localized: "agentQueue.resume", defaultValue: "Resume")
            ) {
                if sidebarProjection.primaryAction == .pause {
                    controller.pause()
                } else {
                    controller.resume()
                }
            }
        }
        .padding(10)
    }

    private var preparationSection: some View {
        let snapshot = preparationSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.preparation.title", defaultValue: "Worker preparation"))
                .font(.subheadline.weight(.semibold))

            HStack {
                Text(String(localized: "agentQueue.preparation.workerCount", defaultValue: "Worker count"))
                Spacer()
                Button {
                    controller.setWorkerCount(snapshot.workerCount - 1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .disabled(snapshot.isWorkerCountDecreaseDisabled)
                .accessibilityLabel(
                    String(localized: "agentQueue.preparation.workerCount.decrease", defaultValue: "Worker 줄이기")
                )

                Text(snapshot.workerCount, format: .number)
                    .monospacedDigit()
                    .frame(minWidth: 20)

                Button {
                    controller.setWorkerCount(snapshot.workerCount + 1)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(snapshot.isWorkerCountIncreaseDisabled)
                .accessibilityLabel(
                    String(localized: "agentQueue.preparation.workerCount.increase", defaultValue: "Worker 늘리기")
                )
            }

            TextField(
                String(
                    localized: "agentQueue.preparation.skill.searchPlaceholder",
                    defaultValue: "Search additional skills"
                ),
                text: $skillQuery
            )
            .textFieldStyle(.roundedBorder)
            .disabled(snapshot.isPreparing)

            LazyVStack(spacing: 8) {
                ForEach(snapshot.profiles) { profile in
                    AgentQueueAgentProfileCard(
                        snapshot: profile,
                        skillOptions: availableSkillRows(for: profile),
                        onAddSkill: { controller.addSkill($0, to: profile.id) },
                        onRemoveSkill: { controller.removeSkill(sourcePath: $0, from: profile.id) },
                        onRolePromptChange: { controller.setRolePrompt($0, for: profile.id) }
                    )
                }
            }

            HStack(spacing: 8) {
                Button(
                    snapshot.showsRetry
                        ? String(localized: "agentQueue.preparation.retry", defaultValue: "Retry")
                        : String(localized: "agentQueue.preparation.prepare", defaultValue: "Prepare Workers")
                ) {
                    Task { await controller.prepareWorkers(allowSkillChanges: false) }
                }
                .disabled(snapshot.isPreparing || controller.hasActiveWork)

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
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "agentQueue.workers.title", defaultValue: "Workers"))
                .font(.subheadline.weight(.semibold))
            LazyVStack(spacing: 6) {
                ForEach(sidebarProjection.agentRows) { row in
                    AgentQueueAgentRow(
                        row: row,
                        actions: AgentQueueAgentRowActions(
                            removeRegistration: {
                                controller.removeRegistration(agentID: row.id)
                            },
                            reprepare: {
                                Task { await controller.prepareWorkers(allowSkillChanges: false) }
                            }
                        )
                    )
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

    private func availableSkillRows(
        for profile: AgentQueueAgentProfileSnapshot
    ) -> [AgentQueueSkillRowSnapshot] {
        let selectedIDs = Set(profile.additionalSkills.map(\.id))
        return skillRows.filter { !selectedIDs.contains($0.id) }
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

private struct AgentQueueAgentRow: View {
    let row: AgentQueueAgentRowSnapshot
    let actions: AgentQueueAgentRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    row.role == .planner
                        ? String(localized: "agentQueue.preparation.planner", defaultValue: "Planner")
                        : row.id
                )
                Spacer()
                Text(readinessText)
                    .font(.caption.weight(.semibold))
            }
            if let surfaceLabel = row.surfaceLabel {
                Text(String.localizedStringWithFormat(
                    String(localized: "agentQueue.worker.surfaceFormat", defaultValue: "surface:%@"),
                    surfaceLabel
                ))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let taskTitle = row.taskTitle {
                Text(taskTitle).font(.caption).lineLimit(2)
            }
            HStack {
                Button(
                    String(
                        localized: "agentQueue.removeRegistration",
                        defaultValue: "Remove Registration"
                    ),
                    action: actions.removeRegistration
                )
                .disabled(!row.canRemoveRegistration)
                Button(
                    String(localized: "agentQueue.reprepare", defaultValue: "Re-prepare"),
                    action: actions.reprepare
                )
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var readinessText: String {
        switch row.readiness {
        case .pending:
            return String(
                localized: "agentQueue.agent.pending",
                defaultValue: "Waiting for handshake"
            )
        case .ready:
            return String(localized: "agentQueue.preparation.phase.ready", defaultValue: "Ready")
        case .notReady:
            return String(localized: "agentQueue.agent.notReady", defaultValue: "Not ready")
        }
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
