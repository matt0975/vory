import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// Run now on a scheduled task: Running… from the first tap, one run however often it is
/// pressed while the gateway works, then Started or Finished, or the gateway's error in plain
/// words. The gateway runs the whole task before it answers, so the pending stretch is long.
@Suite struct CronRunTests {
    private let before = "2026-09-22T07:00:00Z"

    private func job(lastRun: String?, status: String? = "ok", claim: Bool = false, execution: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["job_id": .string("morning-brief"), "name": .string("Morning brief")]
        if let lastRun { o["last_run_at"] = .string(lastRun) }
        if let status { o["last_status"] = .string(status) }
        if claim { o["fire_claim"] = .object(["at": .string("2026-10-06T08:00:00Z"), "by": .string("host:1")]) }
        if let execution { o["latest_execution"] = .object(["status": .string(execution)]) }
        return .object(o)
    }

    @Test func aTapShowsRunningAtOnceAndSwitchesTheButtonOff() {
        var run = CronRun()
        #expect(run.title == "Run now")
        #expect(!run.isBusy)
        let go = run.begin(); #expect(go)
        #expect(run.phase == .running)
        #expect(run.title == "Running…")
        #expect(run.symbol == nil)   // a spinner
        #expect(run.isBusy)
        #expect(run.note?.isProblem == false)
    }

    @Test func tapsWhileARunIsOutSendNothing() {
        var run = CronRun()
        let go = run.begin(); #expect(go)
        let second = run.begin(), third = run.begin()
        #expect(!second && !third)
        #expect(run.attempt == 1)
        #expect(run.phase == .running)
        // Nor while its confirmation shows.
        run.answered(job(lastRun: "2026-10-06T08:00:00Z"), lastRunBefore: before)
        let duringConfirmation = run.begin()
        #expect(!duringConfirmation)
        #expect(run.attempt == 1)
    }

    @Test func aReplyWithTheFinishedRunSaysFinishedWithItsResult() {
        var run = CronRun()
        _ = run.begin()
        run.answered(job(lastRun: "2026-10-06T08:00:00Z", status: "ok"), lastRunBefore: before)
        #expect(run.phase == .finished(result: "ok"))
        #expect(run.title == "Finished")
        #expect(run.symbol == "checkmark.circle")
        #expect(run.note?.text == "Last result: ok.")
        #expect(run.note?.isProblem == false)
    }

    @Test func aFinishedRunThatWentWrongSaysSo() {
        var run = CronRun()
        _ = run.begin()
        run.answered(job(lastRun: "2026-10-06T08:00:00Z", status: "delivery_failed"), lastRunBefore: before)
        #expect(run.phase == .finished(result: "delivery failed"))
        #expect(run.symbol == "exclamationmark.circle")
        #expect(run.note?.text == "Last result: delivery failed.")
        #expect(run.note?.isProblem == true)
    }

    @Test func aReplyWithoutANewRunSaysStarted() {
        var run = CronRun()
        _ = run.begin()
        run.answered(job(lastRun: before), lastRunBefore: before)
        #expect(run.phase == .started)
        #expect(run.title == "Started")
        var empty = CronRun()
        _ = empty.begin()
        empty.answered(.object([:]), lastRunBefore: nil)
        #expect(empty.phase == .started)
    }

    @Test func theConfirmationGivesWayToRunNowAndANewRunCanStart() {
        var run = CronRun()
        _ = run.begin()
        let first = run.attempt
        run.answered(nil, lastRunBefore: before)
        run.settle(attempt: first)
        #expect(run.phase == .idle)
        #expect(run.title == "Run now")
        let go = run.begin(); #expect(go)
        #expect(run.attempt == first + 1)
        // A late settle from the first run does not cut the second one short.
        run.settle(attempt: first)
        #expect(run.phase == .running)
    }

    @Test func aBusyGatewaySaysItIsAlreadyRunning() {
        var run = CronRun()
        _ = run.begin()
        run.failed(HermesAPIError.http(status: 409, detail: "Job is already running or was claimed by another scheduler"))
        #expect(run.phase == .failed("It is already running. Wait for it to finish, then try again."))
        #expect(run.title == "Run now")
        #expect(!run.isBusy)
        #expect(run.note?.isProblem == true)
        // A failure stays until the next tap, which may run again.
        run.settle(attempt: run.attempt)
        #expect(run.note?.isProblem == true)
        let go = run.begin(); #expect(go)
    }

    @Test func errorsReadAsPlainWords() {
        #expect(CronRun.plainWords(HermesAPIError.http(status: 404, detail: "Job not found")) == "The gateway no longer has this task. Go back and refresh the list.")
        #expect(CronRun.plainWords(HermesAPIError.http(status: 400, detail: "Cannot run: the task is finished")) == "The gateway could not run it: Cannot run: the task is finished.")
        #expect(CronRun.plainWords(HermesAPIError.http(status: 500, detail: "")) == "The gateway could not run it (error 500).")
        #expect(CronRun.plainWords(HermesAPIError.transport("Could not connect to the server.")) == "No answer from the gateway: Could not connect to the server.")
        #expect(CronRun.plainWords(HermesAPIError.sessionExpired) == "Your session has expired. Sign in again.")
    }

    @Test func noAnswerWhileTheGatewayStillRunsItIsStartedNotAFailure() {
        let timedOut = HermesAPIError.transport("The request timed out.")
        #expect(CronRun.mayStillBeRunning(after: timedOut))
        #expect(!CronRun.mayStillBeRunning(after: HermesAPIError.http(status: 409, detail: "")))

        var claimed = CronRun()
        _ = claimed.begin()
        claimed.failed(timedOut, jobNow: job(lastRun: before, claim: true), lastRunBefore: before)
        #expect(claimed.phase == .started)
        #expect(claimed.note?.text == "Still running on the gateway. Last run changes when it is done.")

        var executing = CronRun()
        _ = executing.begin()
        executing.failed(timedOut, jobNow: job(lastRun: before, execution: "running"), lastRunBefore: before)
        #expect(executing.phase == .started)

        var done = CronRun()
        _ = done.begin()
        done.failed(timedOut, jobNow: job(lastRun: "2026-10-06T08:03:00Z", status: "ok"), lastRunBefore: before)
        #expect(done.phase == .finished(result: "ok"))

        // Nothing under way and no new run: the run did not happen, and it says why.
        var lost = CronRun()
        _ = lost.begin()
        lost.failed(timedOut, jobNow: job(lastRun: before), lastRunBefore: before)
        #expect(lost.phase == .failed("No answer from the gateway: The request timed out."))
        var unasked = CronRun()
        _ = unasked.begin()
        unasked.failed(timedOut)
        #expect(unasked.phase == .failed("No answer from the gateway: The request timed out."))
    }

    @Test func anUnreadableSuccessStillCountsAsStartedAndACancelLeavesNoTrace() {
        var odd = CronRun()
        _ = odd.begin()
        odd.failed(HermesAPIError.decoding("not JSON"))
        #expect(odd.phase == .started)
        var cancelled = CronRun()
        _ = cancelled.begin()
        cancelled.failed(CancellationError())
        #expect(cancelled.phase == .idle)
        #expect(cancelled.note == nil)
    }

    @Test func answersOutsideARunChangeNothing() {
        var run = CronRun()
        run.answered(job(lastRun: "2026-10-06T08:00:00Z"), lastRunBefore: before)
        run.failed(HermesAPIError.http(status: 409, detail: ""))
        #expect(run.phase == .idle)
    }

    @MainActor @Test func theRunOutlivesThePageThatStartedIt() {
        let store = CronRuns()
        var go = false
        store.update("gw|job") { go = $0.begin() }
        #expect(go)
        // The page reopened: the same key still reads Running… and a tap sends nothing.
        #expect(store.run("gw|job").title == "Running…")
        store.update("gw|job") { go = $0.begin() }
        #expect(!go)
        // Another task, or the same task on another gateway, is its own run.
        #expect(store.run("other|job").phase == .idle)
    }
}
