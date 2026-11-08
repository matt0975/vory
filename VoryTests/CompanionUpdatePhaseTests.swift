import Testing
@testable import Vory

/// #635: Software Update shows the companion's update card in every phase but "up to date", and swaps the two rows
/// inside the closing transaction. The phase comes from the model's flags.
@Suite struct CompanionUpdatePhaseTests {
    @Test func eachPhaseFromTheFlags() {
        #expect(CompanionUpdatePhase.of(available: true, updating: false, console: false, outcome: nil) == .available)
        #expect(CompanionUpdatePhase.of(available: false, updating: false, console: false, outcome: nil) == .upToDate)
        #expect(CompanionUpdatePhase.of(available: true, updating: true, console: true, outcome: nil) == .working)
        #expect(CompanionUpdatePhase.of(available: false, updating: false, console: true, outcome: nil) == .working, "the console still shown")
        #expect(CompanionUpdatePhase.of(available: true, updating: false, console: true, outcome: (false, "Restart failed")) == .working, "a failure")
        #expect(CompanionUpdatePhase.of(available: false, updating: true, console: true, outcome: (true, "Updated")) == .complete)
    }

    /// The closing ease clears the console, the outcome and `updating` in one transaction, after the files are this
    /// build's (update available false): from complete straight to up to date, never back through "available".
    @Test func theClosingEaseGoesFromCompleteToUpToDate() {
        #expect(CompanionUpdatePhase.of(available: false, updating: true, console: true, outcome: (true, "Updated")) == .complete)
        #expect(CompanionUpdatePhase.of(available: false, updating: false, console: false, outcome: nil) == .upToDate)
        // Were update available still true at the ease, the card would show its "available" face for a moment: the
        // fix keeps it false from Update Complete on (the success needs the version and the script read back).
        #expect(CompanionUpdatePhase.of(available: true, updating: false, console: false, outcome: nil) == .available)
    }
}
