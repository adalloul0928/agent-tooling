import AgentToolingCore
import AppKit
import SwiftUI

/// A failed copy batch stays reviewable without growing the wizard to fit
/// every rejection. Expanding the details never selects or skips anything.
struct OnboardingCopyIssuesView: View {
    let issues: [SkillAdoptionRejection]
    let sourcePaths: [String: String]
    @Binding var isExpanded: Bool
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("\(issues.count) \(issues.count == 1 ? "skill needs" : "skills need") attention")
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Hide" : "Show") details for \(issues.count) skills that need attention")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                Spacer(minLength: 8)
                Button("Track without copying", action: onSkip)
                    .buttonStyle(.glass).controlSize(.small)
                    .help("Keep tracking these skills and cancel only their optional personal copies.")
            }
            Text("You can track these skills without a personal copy. Their original installations stay in place.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isExpanded {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(issues) { issue in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(issue.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text(issue.reason).font(.system(size: 13)).foregroundStyle(.secondary)
                                        .lineLimit(2).help(issue.reason)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if let path = sourcePaths[issue.id] {
                                    Button("Show source") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    }
                                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(AgentTheme.blue)
                                    .help(path)
                                    .accessibilityLabel("Show source for \(issue.displayName)")
                                }
                            }
                            .padding(.vertical, 10).padding(.trailing, 8)
                            if issue.id != issues.last?.id { Divider() }
                        }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("Skill copy issues")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .standardPanel(cornerRadius: 12)
    }
}
