import AgentToolingCore

extension LaunchpadCopy.Review {
    // The panel's header.

    /// "Into 2 apps on this Mac. Each step shows what it runs; Cancel writes
    /// nothing."
    static func subtitle(apps: Int) -> String {
        "Into \(CountNoun.app.phrase(apps)) on this Mac. Each step shows what it runs; Cancel writes nothing."
    }

    /// The title while the plan is being read, before it can be counted.
    static let preparingTitle = "Install changes"

    /// What the panel says while it reads the plan (the shipped review
    /// sheet's words).
    static let checking = "Checking destinations and package contents…"

    /// The chip that names this Mac: "This Mac · Juniper".
    static func chip(deviceName: String) -> String {
        "This Mac · \(deviceName)"
    }

    // The library row: what the setup already saved in the library, apart
    // from what reaches an app.

    static let inYourLibrary = "In your library"

    /// "· 7 decisions · these touch no app".
    static func libraryDecisions(_ count: Int) -> String {
        "· \(CountNoun.decision.phrase(count)) · these touch no app"
    }

    static let saved = "Saved"

    /// What VoiceOver says the disclosure is: "collapsed, 7 decisions".
    static func libraryDisclosure(expanded: Bool, decisions: Int) -> String {
        "\(expanded ? "expanded" : "collapsed"), \(CountNoun.decision.phrase(decisions))"
    }

    /// What VoiceOver adds after the row's name and its value.
    static let libraryHint = "These touch no app"

    // Before you approve: the one line of facts about what runs.

    static let beforeYouApprove = "Before you approve"

    /// The left-alone clause: "1 step is left alone".
    static func leftAlone(steps: Int) -> String {
        "\(CountNoun.step.phrase(steps)) \(steps == 1 ? "is" : "are") left alone"
    }

    /// The clean-scan clause, naming what was read: "Release Notes was
    /// checked for risky content; nothing was flagged."
    static func checkedClean(_ names: [String]) -> String {
        "\(LaunchpadCopy.list(names)) \(names.count == 1 ? "was" : "were") checked for risky content; nothing was flagged."
    }

    // The steps.

    /// The eyebrow over the apps' steps: "In your apps · 4 changes".
    static func inYourApps(changes: Int) -> String {
        "In your apps · \(CountNoun.change.phrase(changes))"
    }

    /// An app's group: "2 changes · 1 left alone".
    static func groupSummary(changes: Int, leftAlone: Int, cannotRun: Int = 0) -> String {
        var parts = [CountNoun.change.phrase(changes)]
        if leftAlone > 0 { parts.append("\(leftAlone) left alone") }
        if cannotRun > 0 { parts.append("\(cannotRun) cannot run yet") }
        return parts.joined(separator: " · ")
    }

    /// The state a step left alone shows at its trailing edge.
    static let leftAloneState = "Left alone"

    /// Why a step is left alone: its app has a copy Agent Tooling did not put
    /// there (the shipped sentence).
    static func leftAloneNotOurs(app: String) -> String {
        "Left alone: \(app) already has a copy Agent Tooling did not put there. It won’t be overwritten."
    }

    /// Why a step is left alone: the copy Agent Tooling put there was changed
    /// since.
    static func leftAloneEdited(app: String) -> String {
        "Left alone: the copy in \(app) was changed after Agent Tooling put it there. It won’t be overwritten."
    }

    /// A step listed that no command can be built for: "Will not run · …".
    static func willNotRun(_ reason: String) -> String {
        "Will not run · \(reason)"
    }

    /// What the registration a connection step would replace starts now
    /// (D30), when the app's configuration says: S11's sentence for Agent
    /// Tooling's own connection (§6), "Connected to another copy at <path>.";
    /// for any other connection, "Claude Code starts files from <path> now."
    static func registeredNow(server: String, app: String, path: String?) -> String {
        switch (server == AgentToolingConnection.declaredName, path) {
        case (true, let path?): "Connected to another copy at \(path)."
        case (true, nil): "Connected to another copy."
        case (false, let path?): "\(app) starts \(server) from \(path) now."
        case (false, nil): "\(app) already has \(server) set up another way."
        }
    }

    /// What a replacement risks, under its two commands: a connection whose
    /// add failed after its removal went through is still asked for, so
    /// Apps offers to add it again. Agent Tooling's own connection too: no
    /// Checkup finding looks for it, so §6's "Checkup will say so" would not
    /// come true (owner flag O6).
    static func replaceNote(server: String, app: String) -> String {
        "If adding fails, \(server) is left removed from \(app); Apps will offer to add it again."
    }

    /// Why a connection step is left alone: its app already holds the name,
    /// and no receipt shows Agent Tooling set it up there (§6, S11's
    /// caption).
    static let notOurs = "Agent Tooling did not add this one, so it is left alone."

    /// VoiceOver's name for a numbered step: "Step 1 of 4".
    static func stepNumber(_ number: Int, of total: Int) -> String {
        "Step \(number) of \(total)"
    }

    /// What VoiceOver adds for a step that is running, done or failed.
    static let stepInstalling = "installing"
    static let stepDone = "done"
    static func stepFailed(_ reason: String) -> String {
        "did not finish: \(reason)"
    }

    /// The index of a step that does not run.
    static let noNumber = "–"

    /// What leads each command in a well, as a shell prompt.
    static let prompt = "$ "

    /// The copy button on a well.
    static let copyWell = "Copy"
    static let copied = "Copied"

    // The bar.

    static let cancel = "Cancel"

    /// The caption beside Cancel.
    static let safety = "Changes files on this Mac. Removals go to Agent Tooling’s trash; configuration files are backed up first."

    /// The primary while the install runs: "Installing 2 of 4…"; "Applying
    /// 1 of 2…" when a step takes something out, as the title says Apply
    /// (`PlanReviewLabels.verb`).
    static func installing(_ done: Int, of total: Int, hasRemoval: Bool = false) -> String {
        "\(hasRemoval ? "Applying" : "Installing") \(done) of \(total)…"
    }

    /// The same, as VoiceOver announces it: "Installing 2 of 4."
    static func installingSpoken(_ done: Int, of total: Int, hasRemoval: Bool = false) -> String {
        "\(hasRemoval ? "Applying" : "Installing") \(done) of \(total)."
    }

    /// The library moved while the panel was open (§6, S12).
    static let changedWhileOpen = "Your library changed while this was open. Review again."
    static let reviewAgain = "Review again"

    /// A plan with nothing in it.
    static let nothingToInstall = "Nothing to install."

    /// A plan whose every step is left alone or will not run.
    static let nothingCanRun = "Nothing here can run yet."

    // The library row's lines: one for each decision the setup made in the
    // library, in the order it was made.

    /// "Made Release Notes yours".
    static func madeYours(_ name: String) -> String {
        "Made \(name) yours"
    }

    /// "Made Frontend Design yours, from Claude Code’s copy".
    static func madeYours(_ name: String, fromCopyIn app: String) -> String {
        "Made \(name) yours, from \(app)’s copy"
    }

    /// "Added Supabase, from Claude Code’s catalog".
    static func added(_ name: String, fromCatalogOf app: String) -> String {
        "Added \(name), from \(app)’s catalog"
    }

    static func addedFromSkillsSh(_ name: String) -> String {
        "Added \(name), from skills.sh"
    }

    static func addedWrittenHere(_ name: String) -> String {
        "Added \(name), written here"
    }

    static func addedFromPastedCommand(_ name: String) -> String {
        "Added \(name), from a pasted command"
    }

    /// "Release Notes goes to Codex and Claude Code on every Mac".
    static func goesToEveryMac(_ name: String, apps: String) -> String {
        "\(name) goes to \(apps) on every Mac"
    }

    static func goesToThisMacOnly(_ name: String, apps: String) -> String {
        "\(name) goes to \(apps) on this Mac only"
    }

    static func goes(_ name: String, to apps: String, inProject project: String) -> String {
        "\(name) goes to \(apps) in \(project)"
    }

    /// "Agent Tooling’s own connection, for Codex and Claude Code on this Mac
    /// only".
    static func ownConnection(for apps: String) -> String {
        "Agent Tooling’s own connection, for \(apps) on this Mac only"
    }

    // The result, in the shipped install wording; once a step took
    // something out of an app, "applied" where it says "installed", and
    // "changed" where it says nothing was installed, as the title said Apply.

    static let nothingInstalled = "Nothing was installed."

    /// "Nothing was installed.", or "Nothing was changed." once a step would
    /// have taken something out.
    static func nothingInstalled(hasRemoval: Bool) -> String {
        hasRemoval ? "Nothing was changed." : nothingInstalled
    }

    /// Every app refused: "Nothing was installed. One app did not take it."
    static func nothingInstalled(appsRefusing: Int, hasRemoval: Bool = false) -> String {
        let apps = appsRefusing == 1 ? "One app" : CountNoun.app.phrase(appsRefusing)
        return "\(nothingInstalled(hasRemoval: hasRemoval)) \(apps) did not take it."
    }

    /// `apps` already listed: "Installed to Claude Code and Codex.", or
    /// "Applied to Claude Code."
    static func installed(to apps: String, hasRemoval: Bool = false) -> String {
        "\(pastVerb(hasRemoval)) to \(apps)."
    }

    /// Some apps refused: "Installed to 1 of 2 apps."
    static func installed(_ installed: Int, of total: Int, hasRemoval: Bool = false) -> String {
        "\(pastVerb(hasRemoval)) to \(installed) of \(total) apps."
    }

    /// Some changes went in, though no app took every one of its own:
    /// "Installed 1 of 4 changes."
    static func installedChanges(_ installed: Int, of total: Int, hasRemoval: Bool = false) -> String {
        "\(pastVerb(hasRemoval)) \(installed) of \(CountNoun.change.phrase(total))."
    }

    /// "Installed", or "Applied" once a step took something out.
    private static func pastVerb(_ hasRemoval: Bool) -> String {
        hasRemoval ? "Applied" : "Installed"
    }

    /// The install was stopped after some changes: "Stopped after 2 of 4
    /// changes."
    static func stopped(after installed: Int, of total: Int) -> String {
        "Stopped after \(installed) of \(CountNoun.change.phrase(total))."
    }

    /// The install was stopped before any change went in.
    static let stoppedBeforeAnything = "Stopped before anything was installed."

    /// The same, or "Stopped before anything was changed." once a step would
    /// have taken something out.
    static func stoppedBeforeAnything(hasRemoval: Bool) -> String {
        hasRemoval ? "Stopped before anything was changed." : stoppedBeforeAnything
    }

    /// The receipt: "Installed 4 changes · 9:52 AM", or "Applied 1 change ·
    /// 9:52 AM".
    static func receipt(changes: Int, at time: String, hasRemoval: Bool = false) -> String {
        "\(pastVerb(hasRemoval)) \(CountNoun.change.phrase(changes)) · \(time)"
    }

    /// What a failed step says when its app said nothing.
    static func stepDidNotFinish(in app: String) -> String {
        "\(app) did not finish this step."
    }

    enum Failures {
        /// The plan could not be read, so there is nothing to review.
        static let notChecked = "This Mac’s apps could not be checked. Nothing was changed."
        /// The library's content store is not there, so nothing could be read
        /// before it was written.
        static let noContentStore =
            "This library has no verified content store, so nothing in it could be read before it was written. Nothing was changed."
        /// The library was never read, so no plan exists to review.
        static let notRead = "The library has not been read yet, so there is nothing to review. Nothing was changed."
    }
}

extension CountNoun {
    fileprivate static let app = CountNoun("app")
    fileprivate static let step = CountNoun("step")
    fileprivate static let decision = CountNoun("decision")
}
