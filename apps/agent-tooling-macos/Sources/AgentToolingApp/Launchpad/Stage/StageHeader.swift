import SwiftUI

/// A stage screen's header, at one of two fixed heights so what follows it
/// always starts at the same place.
///
/// The hero header (the screens of the tile sequence) is 106 tall, its title
/// set at `AgentFont.hero`, so the hero well under it always starts at y 150.
/// The page header is 96 tall, its title at `pageTitle`, so content starts at
/// y 140. Two subtitle lines are reserved either way, whatever the subtitle's
/// length.
///
/// VoiceOver reads the eyebrow first, as plain text, then the title as the
/// screen's level-one heading.
struct StageHeader: View {
    enum Level: Sendable {
        case hero
        case page
    }

    let level: Level
    let eyebrow: String
    let title: String
    var subtitle: String?

    init(_ level: Level, eyebrow: String, title: String, subtitle: String? = nil) {
        self.level = level
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
    }

    private var height: CGFloat {
        level == .hero ? StageLayout.Header.heroHeight : StageLayout.Header.pageHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(eyebrow)
                .accessibilitySortPriority(2)
            titleText
                .lineLimit(1)
                .frame(
                    height: level == .hero ? StageLayout.Header.heroTitleLine : StageLayout.Header.pageTitleLine,
                    alignment: .leading
                )
                .padding(.top, level == .hero ? StageLayout.Header.heroTitleGap : StageLayout.Header.pageTitleGap)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
                .accessibilitySortPriority(1)
            if let subtitle {
                Text(subtitle)
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: StageLayout.Header.subtitleMeasure, alignment: .topLeading)
                    .frame(height: StageLayout.Header.subtitleBox, alignment: .topLeading)
                    .padding(.top, level == .hero ? StageLayout.Header.heroSubtitleGap : StageLayout.Header.pageSubtitleGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var titleText: some View {
        switch level {
        case .hero: Text(title).font(AgentFont.hero)
        case .page: Text(title).font(AgentFont.pageTitle)
        }
    }
}

/// The small capital label over a header's title or a group of lines: "Your
/// coding agents", "What happened". Secondary, because it carries meaning.
struct Eyebrow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(AgentFont.captionSemibold)
            .kerning(AgentFont.capsKerning)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: StageLayout.Header.eyebrowLine, alignment: .leading)
            .accessibilityLabel(text)
    }
}

/// A list's label inside a card or a well: "Reads", "Runs", "How your apps
/// sign in". Smaller than an eyebrow, and secondary, never tertiary: each
/// names what the lines under it are.
struct StageListLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(AgentFont.microSemibold)
            .kerning(AgentFont.capsKerning)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityLabel(text)
    }
}
