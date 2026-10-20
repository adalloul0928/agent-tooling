import SwiftUI

extension StageLayout.Macs {
    /// Where a field's help line starts: past the label column and the gap
    /// after it, under the field's own edge.
    static let helpIndent: CGFloat = Size.labelColumn + Space.lg
    /// The room between the address field and the Branch label beside it.
    static let inlineLabelGap: CGFloat = Space.xl
}

/// One row of a stage form, as Settings › Sync's labelled rows read: the
/// label in the 132 pt label column, then what it labels, 12 after it.
struct FormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Space.lg) {
            FormLabel(label)
                .frame(width: Size.labelColumn, alignment: .leading)
            content
        }
    }
}

/// A form's label: medium body text in the label colour, on one line. The
/// field it names carries the same words for VoiceOver.
struct FormLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(AgentFont.bodyMedium)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// The repository's address and branch on one row, the way S17, J01 and V08
/// set them: the address takes what the row leaves, and Branch sits after it
/// with its own label, at the narrow field width.
struct RepositoryFields: View {
    @Binding var address: String
    @Binding var branch: String
    var isLocked = false
    var focusesAddress = false
    var onSubmit: () -> Void = {}

    var body: some View {
        FormRow(LaunchpadCopy.Macs.addressLabel) {
            StageField(
                label: LaunchpadCopy.Macs.addressLabel, placeholder: LaunchpadCopy.Macs.addressPlaceholder, text: $address,
                isLocked: isLocked, focusesFirst: focusesAddress, onSubmit: onSubmit
            )
            .frame(maxWidth: .infinity)
            FormLabel(LaunchpadCopy.Macs.branchLabel)
                .padding(.leading, StageLayout.Macs.inlineLabelGap - Space.lg)
            StageField(
                label: LaunchpadCopy.Macs.branchLabel, placeholder: LaunchpadCopy.Macs.defaultBranch, text: $branch,
                isLocked: isLocked, onSubmit: onSubmit
            )
            .frame(width: Size.fieldNarrow)
        }
    }
}
