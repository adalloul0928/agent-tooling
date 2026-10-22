import SwiftUI

/// Why a stage form did not go on, in the place of the line it stands in
/// for: the warning glyph at the top, a title saying where it stopped, and
/// the cause's own sentence under it, set in even lines so its last words
/// never stand alone. It drops in from the top with its opacity, as an
/// attention banner does, and only fades under Reduce Motion. VoiceOver hears
/// it as it appears and each time its words change, since nothing else on
/// the form moves to say so.
struct StageBanner: View {
    let title: String
    let message: String
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            StatusGlyph(state: .attention, size: Size.glyphLarge)
                .padding(.top, Space.nudge)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(AgentFont.bodySemibold)
                    .wrapsLines()
                BalancedLines {
                    Text(message)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentTheme.warning.opacity(Opacity.bannerWash), in: RoundedRectangle.card)
        .overlay {
            RoundedRectangle.card.strokeBorder(AgentTheme.warning.opacity(Opacity.bannerStroke), lineWidth: Hairline.width)
        }
        .transition(
            motion.resolved(reduceMotion: reduceMotion).animatesDetails
                ? .opacity.combined(with: .offset(y: -AgentMotion.cardRise)) : .opacity
        )
        .accessibilityElement(children: .combine)
        .onAppear { Self.announce(title: title, message: message) }
        .onChange(of: Self.spoken(title: title, message: message)) { _, _ in
            Self.announce(title: title, message: message)
        }
    }

    /// What VoiceOver says as the banner appears: "Couldn’t reach that
    /// repository. Git could not reach github.com from this Mac. …".
    static func spoken(title: String, message: String) -> String {
        message.isEmpty ? title : "\(title). \(message)"
    }

    private static func announce(title: String, message: String) {
        AccessibilityNotification.Announcement(spoken(title: title, message: message)).post()
    }
}

/// Lays one wrapping text out in lines of even length, as CSS's
/// `text-wrap: balance` sets a short message: the narrowest width that still
/// takes no more lines than the whole width would, so the last line is never
/// a word or two on its own. It takes the whole width it is offered, and as
/// many lines as the text would there.
struct BalancedLines: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        guard let width = proposal.width, width > 0, width.isFinite else { return text.sizeThatFits(proposal) }
        return CGSize(width: width, height: text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        let width = Self.balancedWidth(of: text, within: bounds.width)
        text.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
    }

    /// The narrowest width at which `text` keeps the height it has at
    /// `available`: a few halvings between half of it and all of it.
    static func balancedWidth(of text: LayoutSubview, within available: CGFloat) -> CGFloat {
        guard available > 0, available.isFinite else { return available }
        let height = text.sizeThatFits(ProposedViewSize(width: available, height: nil)).height
        let line = text.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        // One line already: nothing to balance.
        guard line.width > available else { return available }
        var low = available / 2
        var high = available
        for _ in 0..<Self.steps {
            let middle = (low + high) / 2
            if text.sizeThatFits(ProposedViewSize(width: middle, height: nil)).height > height {
                low = middle
            } else {
                high = middle
            }
        }
        return high.rounded(.up)
    }

    /// How many halvings narrow the width down: well under a point.
    private static let steps = 10
}
