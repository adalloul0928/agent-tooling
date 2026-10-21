import AppKit
import SwiftUI

/// A caption whose lines come out nearly the same length, as the mockups'
/// fine print sets them (CSS `text-wrap: balance`), where SwiftUI alone
/// would fill each line and leave the last one short.
///
/// It keeps the number of lines the text needs at `maxWidth` and narrows its
/// measure to the least width that still holds the text in that many lines.
/// Before you start's and Let your apps ask's fine print use it.
struct HelperBalancedCaption: View {
    /// The runs of the caption: plain caption words, or a path set in mono
    /// and held on one line.
    struct Run: Equatable {
        let text: String
        var isPath = false

        /// What is drawn: a path's spaces and slashes never end a line.
        var drawn: String {
            guard isPath else { return text }
            return text.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "/", with: "/\u{2060}")
        }
    }

    let runs: [Run]
    var maxWidth: CGFloat = Size.proseMaxWidth
    var alignment: TextAlignment = .center

    init(_ runs: [Run], maxWidth: CGFloat = Size.proseMaxWidth, alignment: TextAlignment = .center) {
        self.runs = runs
        self.maxWidth = maxWidth
        self.alignment = alignment
    }

    init(_ text: String, maxWidth: CGFloat = Size.proseMaxWidth, alignment: TextAlignment = .center) {
        self.init([Run(text: text)], maxWidth: maxWidth, alignment: alignment)
    }

    var body: some View {
        text
            .font(AgentFont.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .frame(width: Self.measure(of: attributed, within: maxWidth), alignment: alignment == .center ? .center : .leading)
            .wrapsLines()
            .accessibilityLabel(Text(verbatim: runs.map(\.text).joined()))
    }

    private var text: Text {
        runs.reduce(Text(verbatim: "")) { sentence, run in
            Text("\(sentence)\(run.isPath ? Text(verbatim: run.drawn).font(AgentFont.monoMicro) : Text(verbatim: run.drawn))")
        }
    }

    /// The caption as AppKit lays text out, in the fonts SwiftUI draws it in.
    private var attributed: NSAttributedString {
        let caption = NSFont.systemFont(ofSize: AgentFont.captionSize)
        let mono = NSFont.monospacedSystemFont(ofSize: AgentFont.microSize, weight: .regular)
        let result = NSMutableAttributedString()
        for run in runs {
            result.append(NSAttributedString(string: run.drawn, attributes: [.font: run.isPath ? mono : caption]))
        }
        return result
    }

    /// The least width, no wider than `maxWidth`, that keeps `text` in as
    /// few lines as `maxWidth` does.
    static func measure(of text: NSAttributedString, within maxWidth: CGFloat) -> CGFloat {
        func lines(at width: CGFloat) -> Int {
            let height = text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]
            ).height
            let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: AgentFont.captionSize))
            return max(1, Int((height / line).rounded()))
        }
        let wanted = lines(at: maxWidth)
        guard wanted > 1 else { return maxWidth }
        var narrow = maxWidth / CGFloat(wanted)
        var wide = maxWidth
        while wide - narrow > Hairline.width {
            let middle = (narrow + wide) / 2
            if lines(at: middle) > wanted { narrow = middle } else { wide = middle }
        }
        return min(maxWidth, wide.rounded(.up) + Hairline.width)
    }
}
