import AgentToolingCore
import SwiftUI

/// Before you start: move Agent Tooling to Applications (S00).
///
/// The poster Welcome draws too, so the relaunch reads as one stage: the mark
/// at rest over the four places. Under it, where this copy runs from and
/// where it goes, and one primary that moves it and reopens. An older copy in
/// Applications is replaced only after a confirm; the same or a newer one is
/// opened instead. A copy the move opened that macOS still runs from a
/// temporary place says so, and offers no second move.
struct LaunchpadMoveScreen: LaunchpadScreen {
    let flow: LaunchpadFlow
    @Environment(\.helperServices) private var services
    @Environment(\.stageMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    init(flow: LaunchpadFlow) {
        self.flow = flow
    }

    var body: some View {
        let model = LaunchpadMoveModel.of(flow)
        let resolved = motion.resolved(reduceMotion: reduceMotion)
        VStack(spacing: 0) {
            StagePoster()
            hello
                .padding(.top, StageLayout.Poster.titleGap)
                .modifier(LaunchpadMoveArrival(order: .title, arrived: arrived, motion: resolved))
            LaunchpadMoveFacts(model: model)
                .padding(.top, Space.xxxl)
                .modifier(LaunchpadMoveArrival(order: .facts, arrived: arrived, motion: resolved))
            LaunchpadMoveCaption(model: model)
                .padding(.top, Space.xl)
                .modifier(LaunchpadMoveArrival(order: .caption, arrived: arrived, motion: resolved))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.use(services)
            arrived = true
        }
        .alert(
            LaunchpadCopy.Helper.replaceQuestion, isPresented: Bindable(model).isConfirmingReplace,
            actions: {
                Button(LaunchpadCopy.Helper.cancel, role: .cancel) {}
                Button(LaunchpadCopy.Helper.replaceAndReopen) { model.replace() }
            },
            message: { Text(LaunchpadCopy.Helper.replaceDetail) })
    }

    private var hello: some View {
        VStack(spacing: Space.md) {
            Text(LaunchpadCopy.Helper.moveTitle)
                .font(AgentFont.hero)
                .lineLimit(1)
                .frame(height: StageLayout.Header.heroTitleLine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text(LaunchpadCopy.Helper.moveSubtitle)
                .font(AgentFont.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Size.proseMaxWidth)
                .wrapsLines()
        }
        .frame(maxWidth: .infinity)
    }

    static func footer(_ flow: LaunchpadFlow) -> StageFooterSpec {
        let model = LaunchpadMoveModel.of(flow)
        let idle = model.phase != .moving
        // While the copy is made, checked and swapped in, there is nothing
        // to leave for: a quit waits for it (D31).
        return StageFooterSpec(
            later: idle ? .setUpLater : .none, showsBack: false,
            secondary: .init(
                title: LaunchpadCopy.Helper.keepItHere, help: LaunchpadCopy.Helper.keepItHereHelp, isEnabled: idle
            ) { model.keepItHere(in: flow) },
            primary: .init(title: model.primaryTitle, isEnabled: idle, busyTitle: LaunchpadCopy.Helper.moving) {
                model.primary()
            })
    }
}

// MARK: - The model

/// Drives app relocation through injected services. Closing is blocked while files
/// are copied, verified, or swapped. Quit waits for a safe cancellation point:
/// before installation the partial copy is removed; afterward it remains unopened.
@MainActor @Observable
final class LaunchpadMoveModel: LaunchpadInterruptible {
    enum Phase: Equatable {
        case ready
        case moving
        /// Nothing moved, or the moved copy could not be opened; the sentence
        /// says which.
        case failed(String)
    }

    /// Let your apps ask opened this step: Keep it here goes back there, onto
    /// Join's detour when it was on one.
    struct AskReturn: Equatable {
        let onDetour: Bool
    }

    let installation: AgentToolingInstallation
    @ObservationIgnored private(set) var services: HelperServices
    private(set) var plan: MoveToApplications.Plan
    /// The copy already in Applications is this version or newer.
    private(set) var existingIsCurrent = false
    /// The disk image the move ejects once the moved copy has opened: the
    /// volume this copy runs from, or the one macOS translocated it from.
    private(set) var ejectedVolume: URL?
    /// The disk image file that volume was opened from.
    private(set) var imageFile: URL?
    private(set) var phase = Phase.ready
    var isConfirmingReplace = false
    /// The copy, its check and the swap are under way.
    private(set) var isMovingFiles = false
    /// Where Keep it here goes, when Let your apps ask opened this step.
    private(set) var returnsToAsk: AskReturn?
    @ObservationIgnored private let homeURL: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var work: Task<Void, Never>?

    init(
        installation: AgentToolingInstallation, homeURL: URL, services: HelperServices, fileManager: FileManager = .default
    ) {
        self.installation = installation
        self.homeURL = homeURL
        self.services = services
        self.fileManager = fileManager
        let engine = MoveToApplications(installation: installation, fileManager: fileManager, services: services)
        plan = engine.plan()
        existingIsCurrent = engine.existingIsCurrent(plan)
        ejectedVolume = engine.diskImageVolume
        imageFile = ejectedVolume.flatMap(services.diskImageFile)
    }

    /// The flow's one model for the step. The screen hands it the services
    /// its environment holds as it appears.
    static func of(_ flow: LaunchpadFlow) -> LaunchpadMoveModel {
        flow.model(for: .move) {
            LaunchpadMoveModel(
                installation: flow.environment.installation(), homeURL: flow.environment.homeURL, services: .live)
        }
    }

    /// Let your apps ask's Move to Applications…: this step, remembering that
    /// it was opened from there, and whether on Join's detour, which going to
    /// another step ends.
    static func open(from flow: LaunchpadFlow) {
        let model = of(flow)
        let onDetour = flow.isDetour
        flow.go(to: .move)
        model.returnsToAsk = flow.step == .move ? AskReturn(onDetour: onDetour) : nil
    }

    /// Acts through `services` from here on, and reads the destination again
    /// with them.
    func use(_ services: HelperServices) {
        self.services = services
        let engine = MoveToApplications(installation: installation, fileManager: fileManager, services: services)
        plan = engine.plan()
        existingIsCurrent = engine.existingIsCurrent(plan)
        ejectedVolume = engine.diskImageVolume
        imageFile = ejectedVolume.flatMap(services.diskImageFile)
    }

    /// A copy a move opened that is still not in Applications: macOS runs it
    /// from a temporary place, and a second move would only loop.
    var isStillOutsideApplications: Bool { services.afterMove != nil && installation.offersMove }

    var primaryTitle: String {
        let copy = LaunchpadCopy.Helper.self
        if isStillOutsideApplications { return copy.quit }
        guard plan.existing != nil else { return copy.moveAndReopen }
        return existingIsCurrent ? copy.openFromApplicationsTitle : copy.replaceAndReopenEllipsis
    }

    /// Row 1's value: where this copy runs from, in words, over its path, the
    /// path in the forms the row takes the longest of that fits.
    var runningFrom: (words: String, paths: [String]) {
        let copy = LaunchpadCopy.Helper.self
        let path = Self.path(of: installation.bundleURL)
        switch installation.location {
        case .diskImage(let volume, _):
            return (copy.diskImage(named: volume), [path])
        case .translocated:
            return (copy.temporaryPlace, Self.translocatedPaths(installation.bundleURL))
        case .elsewhere(let folder):
            let downloads = homeURL.appending(path: "Downloads", directoryHint: .isDirectory)
            let words = Self.samePlace(folder, downloads) ? copy.downloadsFolder : copy.folderOutsideApplications
            return (words, [PathDisplay.abbreviatingHome(path, home: homeURL)])
        case .applications, .developmentBuild:
            return (copy.folderOutsideApplications, [PathDisplay.abbreviatingHome(path, home: homeURL)])
        }
    }

    /// Row 2's path: where the copy goes.
    var destinationPath: String {
        PathDisplay.abbreviatingHome(Self.path(of: plan.destination), home: homeURL)
    }

    /// Row 2's caption, when a copy is already there.
    var destinationNote: String? {
        guard plan.existing != nil else { return nil }
        return existingIsCurrent
            ? LaunchpadCopy.Helper.copyAlreadyThere(version: plan.existingVersion) : LaunchpadCopy.Helper.olderCopyThere
    }

    /// The fine print under the facts: a copy from a disk image (one macOS
    /// translocated from it included) says the image is ejected.
    var caption: String {
        let copy = LaunchpadCopy.Helper.self
        if isStillOutsideApplications { return copy.stillTranslocated }
        guard ejectedVolume != nil else { return copy.movesFromFolder }
        guard let imageFile else { return copy.movesFromDiskImage }
        let folder = imageFile.deletingLastPathComponent()
        let downloads = homeURL.appending(path: "Downloads", directoryHint: .isDirectory)
        let place = Self.samePlace(folder, downloads) ? "Downloads" : folder.lastPathComponent
        // A file name held whole: a non-breaking hyphen never ends a line.
        let file = imageFile.lastPathComponent.replacingOccurrences(of: "-", with: "\u{2011}")
        return copy.movesFromDiskImage + " " + copy.imageStays(file, in: place)
    }

    // MARK: Acting

    /// The primary: quit to reopen from Applications, open the copy already
    /// there, confirm replacing an older one, or move.
    func primary() {
        guard phase != .moving else { return }
        if isStillOutsideApplications {
            services.terminate()
            return
        }
        if let existing = plan.existing {
            if existingIsCurrent {
                run(movingFiles: false) { engine, _ in await engine.open(existing) }
            } else {
                isConfirmingReplace = true
            }
            return
        }
        run(movingFiles: true) { engine, opening in await engine.move(replacingExisting: false, beforeOpening: opening) }
    }

    /// The confirm's Replace and reopen.
    func replace() {
        guard phase != .moving else { return }
        run(movingFiles: true) { engine, opening in await engine.move(replacingExisting: true, beforeOpening: opening) }
    }

    /// Keep it here: Let your apps ask says why it waits. Opened from Let
    /// your apps ask it goes back there, onto Join's detour again when it was
    /// on one; a revisit of this step goes to Home; otherwise on to Welcome.
    func keepItHere(in flow: LaunchpadFlow) {
        guard phase != .moving else { return }
        flow.outcomes.helperUnavailable = LaunchpadCopy.Helper.moveFirst
        if let back = returnsToAsk {
            returnsToAsk = nil
            // The flow puts Join's detour back only on the way from You
            // joined, so the way back there goes through it.
            if back.onDetour { flow.go(to: .arrivals) }
            flow.go(to: .ask)
        } else if case .revisit = flow.entry {
            flow.advance()
        } else if flow.isPostCommit {
            flow.go(to: .ask)
        } else {
            flow.advance()
        }
    }

    // MARK: Quitting

    /// Finishing while the copy is made, checked and swapped in; idle from
    /// the moment the moved copy is opened, so the quit that follows it is
    /// not held up waiting for itself.
    var interruption: LaunchpadInterruption {
        isMovingFiles ? .finishing(LaunchpadCopy.Helper.moving) : .idle
    }

    /// A quit while the move is under way: it stops at its next safe point
    /// and is waited out.
    func interrupt() async {
        work?.cancel()
        await work?.value
    }

    /// The failure banner's Show in Finder: the Applications folder.
    func revealDestination() {
        services.reveal(plan.destination.deletingLastPathComponent())
    }

    /// Runs one move or one open. `movingFiles` when it makes a copy first:
    /// the move is finishing until the copy is about to be opened.
    private func run(
        movingFiles: Bool,
        _ act: @escaping @MainActor (MoveToApplications, _ opening: @escaping @MainActor () -> Void) async -> MoveToApplications.Outcome
    ) {
        phase = .moving
        isMovingFiles = movingFiles
        let engine = MoveToApplications(installation: installation, fileManager: fileManager, services: services)
        // The task holds the model until the move ends, so the callback that
        // ends the finishing window may hold it too.
        work = Task {
            let outcome = await act(engine) { self.isMovingFiles = false }
            isMovingFiles = false
            switch outcome {
            case .relaunching:
                // The new copy is opening and this one is quitting: the
                // primary stays busy, so nothing moves twice.
                break
            case .needsReplaceConfirmation:
                use(services)
                phase = .ready
                isConfirmingReplace = true
            case .openExistingInstead:
                use(services)
                phase = .ready
            case .failed(let sentence):
                use(services)
                phase = .failed(sentence)
            }
        }
    }

    // MARK: Words

    /// A translocated path as the mockups set it, the temporary folders'
    /// random names elided, `/private/var/folders/…/AppTranslocation/…/Agent
    /// Tooling.app`, then shorter still, `…/AppTranslocation/…/Agent
    /// Tooling.app`, for a row too narrow for the first.
    static func translocatedPaths(_ bundle: URL) -> [String] {
        let parts = Array(bundle.standardizedFileURL.pathComponents.dropFirst())
        guard let index = parts.firstIndex(of: "AppTranslocation"), let name = parts.last else {
            return [path(of: bundle)]
        }
        let tail = ["AppTranslocation", "…", name]
        return [
            "/" + (Array(parts.prefix(min(3, index))) + ["…"] + tail).joined(separator: "/"),
            (["…"] + tail).joined(separator: "/"),
        ]
    }

    /// A bundle's path as a person reads it: no trailing slash.
    static func path(of url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func samePlace(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}

// MARK: - The facts

/// Where this copy runs from and where it goes: two 56 pt rows in a 520 card,
/// a 132 label column, the second row's hairline 16 in. A value that is only a
/// path is the answer, so it is set in mono at label colour.
private struct LaunchpadMoveFacts: View {
    let model: LaunchpadMoveModel

    var body: some View {
        let from = model.runningFrom
        VStack(spacing: 0) {
            row(LaunchpadCopy.Helper.runningFrom) {
                Text(from.words)
                    .font(AgentFont.body)
                    .lineLimit(1)
                ViewThatFits(in: .horizontal) {
                    ForEach(from.paths, id: \.self) { path in
                        Text(path)
                            .font(AgentFont.mono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(LaunchpadMoveModel.path(of: model.installation.bundleURL))
            }
            row(LaunchpadCopy.Helper.movesTo, separated: true) {
                HStack(spacing: Space.md) {
                    Text(model.destinationPath)
                        .font(AgentFont.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.phase == .moving {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let note = model.destinationNote {
                    Text(note)
                        .font(AgentFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: StageLayout.Facts.width)
        .stageCard()
        .frame(maxWidth: .infinity)
    }

    private func row(_ label: String, separated: Bool = false, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: Space.lg) {
            Text(label)
                .font(AgentFont.bodyMedium)
                .frame(width: Size.labelColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: Space.xxs) {
                value()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: StageLayout.Facts.row)
        // Drawn over the row's top edge: two rows, 112 tall in all.
        .overlay(alignment: .top) {
            if separated { Hairline(indent: Space.xl) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The caption

/// The fine print under the facts, at the 520 measure, or the failure in its
/// place with Show in Finder.
private struct LaunchpadMoveCaption: View {
    let model: LaunchpadMoveModel

    var body: some View {
        Group {
            if case .failed(let sentence) = model.phase {
                HStack(spacing: Space.lg) {
                    StatusGlyph(state: .attention, size: Size.glyphLarge)
                    Text(sentence)
                        .font(AgentFont.caption)
                        .wrapsLines()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(LaunchpadCopy.Helper.showInFinder) { model.revealDestination() }
                        .buttonStyle(.glass)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.lg)
                .background(AgentTheme.warning.opacity(Opacity.bannerWash), in: RoundedRectangle.card)
                .overlay {
                    RoundedRectangle.card.strokeBorder(AgentTheme.warning.opacity(Opacity.bannerStroke), lineWidth: Hairline.width)
                }
                .accessibilityElement(children: .contain)
                .onAppear { AccessibilityNotification.Announcement(sentence).post() }
            } else {
                HelperBalancedCaption(model.caption)
            }
        }
        .frame(maxWidth: Size.proseMaxWidth)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Arriving

/// The title, the facts and the caption fade in 70 ms apart as the stage
/// appears, from 98%. Under Reduce Motion a fade only; a still draws the end.
private struct LaunchpadMoveArrival: ViewModifier {
    enum Order: Int {
        case title
        case facts
        case caption
    }

    let order: Order
    let arrived: Bool
    let motion: StageMotion

    func body(content: Content) -> some View {
        let shown = arrived || motion == .still
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || motion != .full ? 1 : AgentMotion.appearScale)
            .animation(animation, value: shown)
    }

    private var animation: Animation? {
        switch motion {
        case .full: AgentMotion.selection.delay(AgentMotion.revealStagger * Double(order.rawValue))
        case .reduced: AgentMotion.quick
        case .still: nil
        }
    }
}
