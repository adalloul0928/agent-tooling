extension LaunchpadCopy.Found {
    /// The sign-in line under a read app's tile.
    enum SignIn {
        /// While the app's sign-in read runs.
        static let checking = "Checking sign-in…"
        /// For an app whose sign-in this build cannot read (Gemini CLI), or
        /// whose read found nothing.
        static let cannotCheck = "Can’t check sign-in yet"
        static let notSignedIn = "Not signed in"
    }
}
