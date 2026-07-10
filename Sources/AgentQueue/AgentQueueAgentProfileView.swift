import Foundation
import SwiftUI

struct AgentQueueSkillRowSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sourcePath: String

    init(selection: AgentQueueSkillSelection) {
        id = AgentQueueSkillPath.normalize(selection.sourcePath)
        name = selection.name
        sourcePath = selection.sourcePath
    }

    var selection: AgentQueueSkillSelection {
        AgentQueueSkillSelection(name: name, sourcePath: sourcePath)
    }
}

struct AgentQueueAgentProfileSnapshot: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var mandatorySkill: String
    var additionalSkills: [AgentQueueSkillRowSnapshot]
    var rolePrompt: String
    var statusText: String
    var errorMessage: String?
    var requiresPreparation: Bool
    var isEditingDisabled: Bool

    init(
        profile: AgentQueueAgentProfile,
        record: AgentQueueAgentPreparationRecord?,
        isEditingDisabled: Bool,
        isReady: Bool? = nil
    ) {
        id = profile.id
        title = Self.title(agentID: profile.id)
        mandatorySkill = profile.id == AgentQueueAgentID.planner
            ? "$\(AgentQueueRoleSkill.planner.rawValue)"
            : "$\(AgentQueueRoleSkill.worker.rawValue)"
        additionalSkills = profile.additionalSkills.map(AgentQueueSkillRowSnapshot.init(selection:))
        rolePrompt = profile.rolePrompt
        errorMessage = record?.errorMessage
        self.isEditingDisabled = isEditingDisabled

        let profileMatches = record?.appliedProfileFingerprint ==
            AgentQueueProfileFingerprint.make(profile)
        let recordIsReady = record?.phase == .ready && record?.surfaceID != nil && profileMatches
        requiresPreparation = !(isReady ?? recordIsReady)
        statusText = Self.statusText(
            phase: record?.phase ?? .notPrepared,
            requiresPreparation: requiresPreparation
        )
    }

    private static func title(agentID: String) -> String {
        guard agentID != AgentQueueAgentID.planner,
              let index = AgentQueueAgentID.workerIDs.firstIndex(of: agentID) else {
            return String(
                localized: "agentQueue.profile.plannerTitle",
                defaultValue: "Planner"
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "agentQueue.profile.workerTitleFormat",
                defaultValue: "Worker %d"
            ),
            index + 1
        )
    }

    private static func statusText(
        phase: AgentQueueAgentPreparationPhase,
        requiresPreparation: Bool
    ) -> String {
        switch phase {
        case .preparing:
            return String(
                localized: "agentQueue.profile.status.preparing",
                defaultValue: "준비 중…"
            )
        case .failed:
            return String(
                localized: "agentQueue.profile.status.failed",
                defaultValue: "준비 실패"
            )
        case .ready where !requiresPreparation:
            return String(
                localized: "agentQueue.profile.status.ready",
                defaultValue: "준비됨"
            )
        case .notPrepared, .ready:
            return String(
                localized: "agentQueue.profile.preparationRequired",
                defaultValue: "재준비 필요"
            )
        }
    }
}

struct AgentQueueAgentProfileCard: View {
    let snapshot: AgentQueueAgentProfileSnapshot
    let skillOptions: [AgentQueueSkillRowSnapshot]
    let onAddSkill: (AgentQueueSkillSelection) -> Void
    let onRemoveSkill: (String) -> Void
    let onRolePromptChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(snapshot.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            Text(
                String(
                    localized: "agentQueue.profile.mandatorySkill",
                    defaultValue: "필수 스킬"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Label(snapshot.mandatorySkill, systemImage: "lock.fill")
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))

            HStack {
                Text(
                    String(
                        localized: "agentQueue.profile.additionalSkills",
                        defaultValue: "추가 스킬"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    if skillOptions.isEmpty {
                        Text(
                            String(
                                localized: "agentQueue.preparation.skill.none",
                                defaultValue: "None"
                            )
                        )
                    } else {
                        ForEach(skillOptions) { row in
                            Button {
                                onAddSkill(row.selection)
                            } label: {
                                Text("\(row.name) — \(row.sourcePath)")
                            }
                        }
                    }
                } label: {
                    Label(
                        String(
                            localized: "agentQueue.profile.addSkill",
                            defaultValue: "스킬 추가"
                        ),
                        systemImage: "plus.circle"
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(snapshot.isEditingDisabled)
            }

            if snapshot.additionalSkills.isEmpty {
                Text(
                    String(
                        localized: "agentQueue.preparation.skill.none",
                        defaultValue: "None"
                    )
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            } else {
                ForEach(snapshot.additionalSkills) { skill in
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                                .font(.caption.weight(.medium))
                            Text(skill.sourcePath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 4)
                        Button {
                            onRemoveSkill(skill.sourcePath)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(snapshot.isEditingDisabled)
                        .accessibilityLabel(
                            String.localizedStringWithFormat(
                                String(
                                    localized: "agentQueue.profile.removeSkillAccessibility",
                                    defaultValue: "%@ 스킬 제거"
                                ),
                                skill.name
                            )
                        )
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
            }

            Text(
                String(
                    localized: "agentQueue.profile.rolePrompt",
                    defaultValue: "역할 프롬프트"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if snapshot.rolePrompt.isEmpty {
                    Text(
                        String(
                            localized: "agentQueue.profile.rolePromptPlaceholder",
                            defaultValue: "이 agent의 역할과 책임을 입력하세요."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                }
                TextEditor(
                    text: Binding(
                        get: { snapshot.rolePrompt },
                        set: onRolePromptChange
                    )
                )
                .font(.caption.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72)
                .disabled(snapshot.isEditingDisabled)
            }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

            if snapshot.isEditingDisabled {
                Text(
                    String(
                        localized: "agentQueue.profile.editingDisabledActiveWork",
                        defaultValue: "진행 중인 작업이 있어 프로필을 편집할 수 없습니다."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let errorMessage = snapshot.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12)))
        .accessibilityIdentifier("AgentQueue.profile.\(snapshot.id)")
    }

    private var statusColor: Color {
        if snapshot.errorMessage != nil { return .red }
        return snapshot.requiresPreparation ? .orange : .secondary
    }
}
