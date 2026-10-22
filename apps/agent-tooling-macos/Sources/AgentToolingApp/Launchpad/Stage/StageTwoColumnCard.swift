import SwiftUI

/// Two columns in one stage card, a hairline between them: what was found,
/// what an app can look up beside what it can ask, what travels beside what
/// stays, the checks beside the progress. The columns share the card's width
/// equally, or the trailing one takes `trailingWidth` and the leading one the
/// rest. With `hidesContent`, only the card's edges are drawn: what a screen
/// under the review panel shows in the strips beside it.
struct StageTwoColumnCard<Leading: View, Trailing: View>: View {
    var trailingWidth: CGFloat?
    var hidesContent: Bool
    let leading: Leading
    let trailing: Trailing

    init(
        trailingWidth: CGFloat? = nil, hidesContent: Bool = false, @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.trailingWidth = trailingWidth
        self.hidesContent = hidesContent
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .topLeading)
            if let trailingWidth {
                trailing
                    .frame(width: trailingWidth, alignment: .topLeading)
            } else {
                trailing
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .overlay(alignment: trailingWidth == nil ? .center : .trailing) {
            Hairline(.vertical)
                .padding(.trailing, trailingWidth ?? 0)
        }
        .opacity(hidesContent ? 0 : 1)
        .stageCard()
    }
}
