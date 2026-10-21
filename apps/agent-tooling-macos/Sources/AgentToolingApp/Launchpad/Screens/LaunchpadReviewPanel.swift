import AgentToolingCore
import SwiftUI

/// Modal setup review using the shared scoped-plan model. Saved library intent is
/// separate from client changes. Only fresh ⌘Return applies; Escape cancels before
/// execution. The underlying footer is unmounted, and VoiceOver and keyboard focus
/// stay in the panel. Per-step progress and results follow actual execution.
struct LaunchpadReviewPanel: View {
    let flow: LaunchpadFlow
    let review: ScopedPlanReview
    /// Whether the panel has risen into place.
    @State private var appeared = false
    @AccessibilityFocusState private var titleFocused: Bool
    /// The keyboard, on the panel itself.
    @FocusState private var panelFocused: Bool
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            summary
                .padding(.top, Space.md)
                .padding(.horizontal, Space.xxxl)
            // Only the steps scroll, so the rows above keep the panel's whole
            // width whatever scroller this Mac shows.
            ScrollView {
                content
                    .padding(.horizontal, Space.xxxl)
                    .padding(.bottom, Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            bar
        }
        .frame(width: StageLayout.ReviewPanel.size.width, height: StageLayout.ReviewPanel.size.height)
        // Only what is inside is clipped, so the palette's shadow falls
        // around the panel onto the scrim.
        .clipShape(RoundedRectangle.panel)
        .background { RoundedRectangle.panel.fill(AgentTheme.contentBackground).elevation(.palette) }
        .overlay { ReviewPanelEdge() }
        // It rises 12 pt into place with its fade; under Reduce Motion and in
        // a still it is simply there.
        .opacity(rising ? 0 : 1)
        .offset(x: StageLayout.ReviewPanel.origin.x, y: StageLayout.ReviewPanel.origin.y + rise)
        // ⌘↩ installs only while the plan waits on it; once there is a
        // result, or the plan went stale, ↩ is the bar's own again.
        .commandReturnAction(
            isActive: Self.awaitsCommandReturn(review), isReady: review.canInstall, perform: install,
            onPlainReturn: { flow.showCommandReturnHint() }
        )
        // The binding makes the panel focusable while ⌘↩ is the panel's; it
        // takes the keyboard as it appears, even from a list under it that
        // had it, which a default focus would leave where it was.
        .focused($panelFocused)
        // Space opens the library row's decisions in place. Outside the ⌘↩
        // binding, so a press on the panel reaches it.
        .onKeyPress(.space) {
            guard review.libraryLine != nil else { return .ignored }
            review.isLibraryExpanded.toggle()
            return .handled
        }
        .task {
            guard !review.hasBegunReading else { return }
            await review.prepare()
        }
        .onAppear {
            titleFocused = true
            panelFocused = true
            withAnimation(AgentMotion.selection) { appeared = true }
        }
        .onChange(of: review.progressAnnouncement) { _, spoken in
            guard let spoken else { return }
            var announcement = AttributedString(spoken)
            announcement.accessibilitySpeechAnnouncementPriority = .low
            AccessibilityNotification.Announcement(announcement).post()
        }
        .animation(motion.resolved(reduceMotion: reduceMotion) == .still ? nil : AgentMotion.quick, value: review.phase)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(review.title)
    }

    /// Whether the panel is still below its place, about to rise into it.
    private var rising: Bool {
        motion.resolved(reduceMotion: reduceMotion).animatesDetails && !appeared
    }

    /// How far below its place the panel is.
    private var rise: CGFloat { rising ? AgentMotion.panelRise : 0 }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(review.phase == .preparing ? LaunchpadCopy.Review.preparingTitle : review.title)
                    .font(AgentFont.pageTitle)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h1)
                    .accessibilityFocused($titleFocused)
                // Only while something runs: with nothing to approve there is
                // no app it goes into and no Cancel to speak of.
                Text(review.subtitle)
                    .font(AgentFont.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .opacity(review.runnableCount > 0 ? 1 : 0)
            }
            Spacer(minLength: Space.lg)
            if let chip = review.chip {
                Chip(text: chip, style: .outline)
                    .padding(.top, Space.xxs)
            }
        }
        .padding(.top, Space.xl)
        .padding(.horizontal, Space.xxxl)
    }

    // MARK: Body

    /// The library row and Before you approve: what is already saved, and
    /// the facts about what runs.
    private var summary: some View {
        @Bindable var review = review
        return VStack(alignment: .leading, spacing: Space.xxs) {
            if let line = review.libraryLine, let decisions = review.libraryDecisions {
                ReviewLibraryRow(
                    line: line, lines: decisions.lines, disclosure: review.libraryDisclosureValue(expanded:),
                    hint: review.libraryHint, isExpanded: $review.isLibraryExpanded)
            }
            if let line = review.beforeYouApprove {
                ReviewSafetyRow(text: line)
            }
        }
        .animation(
            motion.resolved(reduceMotion: reduceMotion) == .full ? AgentMotion.actionBar : nil, value: review.isLibraryExpanded)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch review.phase {
            case .preparing:
                HStack(spacing: Space.md) {
                    ProgressView().controlSize(.small)
                    Text(LaunchpadCopy.Review.checking)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Space.lg)
            case .failed(let message):
                NoteLine(symbol: "exclamationmark.triangle", text: message, alignment: .leading)
                    .padding(.top, Space.lg)
            case .ready, .stale, .running, .finished, .notRun:
                steps
            }
        }
    }

    @ViewBuilder private var steps: some View {
        if !review.groups.isEmpty {
            Eyebrow(review.appsLabel)
                .padding(.top, Space.md)
            ForEach(review.groups) { group in
                ReviewAppHeader(client: group.client, summary: group.summary)
                    .padding(.top, Space.xxs)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(group.steps) { step in
                        ReviewStepRow(step: step, accessibilityText: review.accessibilityLabel(for: step))
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: Space.lg) {
            switch review.phase {
            case .finished(let outcome):
                result(outcome)
                Spacer(minLength: Space.md)
                continueButton
            case .stale:
                cancelButton
                problem(LaunchpadCopy.Review.changedWhileOpen)
                Spacer(minLength: Space.md)
                reviewAgainButton
            case .notRun(let reason), .failed(let reason):
                cancelButton
                problem(reason)
                Spacer(minLength: Space.md)
                reviewAgainButton
            case .ready where review.hasNothingToRun:
                // Nothing listed, or nothing listed can run: there is nothing
                // to approve, and Continue writes nothing.
                Text(Self.result(of: review) ?? LaunchpadCopy.Review.nothingToInstall)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.md)
                continueButton
            case .preparing, .ready, .running:
                cancelButton
                safety
                Spacer(minLength: Space.md)
                if flow.commandReturnHint, review.phase == .ready {
                    Text(LaunchpadCopy.Footer.commandReturnHint)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .transition(.opacity)
                }
                installButton
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, Space.xxxl)
        .frame(height: Size.sheetBarHeight)
        .overlay(alignment: .top) { Hairline() }
    }

    private var safety: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "lock.shield")
                .font(.system(size: Size.glyphSmall))
                .accessibilityHidden(true)
            // Never cut short: beside the plain-↩ hint it takes a third line,
            // which the bar has room for.
            Text(LaunchpadCopy.Review.safety)
                .lineLimit(Self.safetyLines)
                .wrapsLines()
        }
        .font(AgentFont.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: Size.fieldWide, alignment: .leading)
        .layoutPriority(-1)
    }

    private var cancelButton: some View {
        Button {
            flow.escape()
        } label: {
            HStack(spacing: Space.sm) {
                Text(LaunchpadCopy.Review.cancel)
                KeyCombo(shortcut: .cancelAction)
            }
        }
        .buttonStyle(.glass)
        .keyboardShortcut(.cancelAction)
        .disabled(review.isBusy)
        .fixedSize()
    }

    private var installButton: some View {
        Button(action: install) {
            HStack(spacing: Space.sm) {
                Text(review.progressLine ?? (review.phase == .preparing ? LaunchpadCopy.Review.preparingTitle : review.title))
                    .contentTransition(motion.resolved(reduceMotion: reduceMotion) == .full ? .numericText() : .identity)
                if !review.isBusy {
                    KeyCombo(shortcut: StageShortcut.commandReturn)
                        .modifier(KeycapFlash(trigger: flow.commandReturnFlash))
                }
            }
            .environment(\.keycapOnAccent, true)
        }
        .primaryActionStyle()
        .disabled(!review.canInstall)
        .accessibilityHint(LaunchpadCopy.Footer.commandReturnAccessibilityHint)
        .fixedSize()
    }

    private var continueButton: some View {
        Button {
            // A held ↩ must not race on past the result.
            guard !LaunchpadKeyRouter.isRepeatKeyEvent() else { return }
            flow.advance()
        } label: {
            HStack(spacing: Space.sm) {
                Text(LaunchpadCopy.Footer.continue)
                KeyCombo(shortcut: .defaultAction)
            }
            .environment(\.keycapOnAccent, true)
        }
        .primaryActionStyle()
        .keyboardShortcut(.defaultAction)
        .fixedSize()
    }

    private var reviewAgainButton: some View {
        Button {
            guard !LaunchpadKeyRouter.isRepeatKeyEvent() else { return }
            Task { await review.reviewAgain() }
        } label: {
            HStack(spacing: Space.sm) {
                Text(LaunchpadCopy.Review.reviewAgain)
                KeyCombo(shortcut: .defaultAction)
            }
            .environment(\.keycapOnAccent, true)
        }
        .primaryActionStyle()
        .keyboardShortcut(.defaultAction)
        .fixedSize()
    }

    private func result(_ outcome: DeploymentOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: outcome.isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: Size.glyph))
                .foregroundStyle(outcome.isComplete ? AgentTheme.ok : AgentTheme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(outcome.summary)
                    .font(AgentFont.bodyMedium)
                Text(outcome.receiptLine)
                    .font(AgentFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    private func problem(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Size.glyphSmall))
                .foregroundStyle(AgentTheme.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(AgentFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .wrapsLines()
        }
        .layoutPriority(-1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Acting

    /// ⌘↩ or a click on Install.
    private func install() {
        Self.install(review, flow: flow)
    }

    /// The install, with what the stage keeps of it, then the stage audit
    /// over what it left (D34). The review is running before this returns,
    /// so a ⎋ handled next finds Cancel waiting. The task ends once the audit
    /// has; nil when nothing could be installed.
    @discardableResult
    static func install(_ review: ScopedPlanReview, flow: LaunchpadFlow) -> Task<Void, Never>? {
        review.whenInstalled = { flow.outcomes.install = $0 }
        guard let installing = review.begin() else { return nil }
        return Task {
            await installing.value
            guard case .finished = review.phase else { return }
            await flow.runStageAudit()
        }
    }

    /// The lines the safety caption may take.
    private static let safetyLines = 3

    /// Whether the panel is where ⌘↩ installs: while the plan is read or is
    /// waiting on it. A result, a stale plan, or nothing that can run hands
    /// ↩ back to the bar.
    static func awaitsCommandReturn(_ review: ScopedPlanReview) -> Bool {
        switch review.phase {
        case .preparing: true
        case .ready: !review.hasNothingToRun
        case .stale, .running, .finished, .notRun, .failed: false
        }
    }

    /// What the bar says once there is nothing left to approve: the install's
    /// result, that the plan had nothing in it, or that nothing in it can run.
    /// Continue follows each.
    static func result(of review: ScopedPlanReview) -> String? {
        switch review.phase {
        case .finished(let outcome): outcome.summary
        case .ready where review.hasNothingToRun:
            review.listedCount == 0 ? LaunchpadCopy.Review.nothingToInstall : LaunchpadCopy.Review.nothingCanRun
        default: nil
        }
    }
}

/// The panel's edge: a hairline around it, lit along its top, as the stage's
/// own rim is.
private struct ReviewPanelEdge: View {
    var body: some View {
        RoundedRectangle.panel
            .strokeBorder(AgentTheme.stageRimEdge, lineWidth: Hairline.width)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AgentTheme.stageRimTop)
                    .frame(height: Hairline.width)
                    .padding(.horizontal, Radius.xl)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
