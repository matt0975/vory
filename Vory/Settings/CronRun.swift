import Foundation
import Observation
import VoryCore

/// Run now on a scheduled task, as its button shows it. The gateway runs the whole task before it
/// answers the request (its reply is the job after the run), so the old button looked untouched
/// for as long as the task took and testers pressed it again. Now a tap turns it into Running… at
/// once and switches it off until the gateway answers, and taps meanwhile send nothing. Then a
/// short Started or Finished, or what went wrong in plain words.
struct CronRun: Equatable {
    enum Phase: Equatable {
        case idle
        /// The request is out and the gateway is working on it.
        case running
        /// The gateway took it but has not said it is done: it stopped answering mid-run, and
        /// asked again it shows the run still going.
        case started
        /// The gateway's reply carries the finished run; `result` is its last status.
        case finished(result: String?)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Counts runs, so the pause after one run's confirmation cannot cut short a later run.
    private(set) var attempt = 0

    /// How long Started or Finished stays on the button before it reads Run now again.
    static let confirmationSeconds: Double = 3

    /// Off while a run is out and while its confirmation shows: a press then would only start
    /// the same task twice.
    var isBusy: Bool {
        switch phase {
        case .running, .started, .finished: return true
        case .idle, .failed: return false
        }
    }

    /// A tap. True when a run should go to the gateway; never while one is out.
    mutating func begin() -> Bool {
        guard !isBusy else { return false }
        attempt += 1
        phase = .running
        return true
    }

    /// The gateway answered the run. `lastRunBefore` is the job's last run when it was tapped:
    /// a reply with a newer one is the run itself, done.
    mutating func answered(_ reply: JSONValue?, lastRunBefore: String?) {
        guard phase == .running else { return }
        if let reply, Self.ranSince(lastRunBefore, reply) {
            phase = .finished(result: Self.result(of: reply))
        } else {
            phase = .started
        }
    }

    /// The run's request failed. `jobNow` is the job as the gateway shows it afterwards, asked
    /// for only when the request got no answer at all (`mayStillBeRunning`): a task that takes
    /// longer than the app waits for an answer is still running on the gateway, and calling that
    /// a failure is what made people press again.
    mutating func failed(_ error: Error, jobNow: JSONValue? = nil, lastRunBefore: String? = nil) {
        guard phase == .running else { return }
        if error is CancellationError { phase = .idle; return }
        if let e = error as? HermesAPIError {
            switch e {
            case .decoding:
                // A 2xx the app could not read: the gateway took the run all the same.
                phase = .started
                return
            case .transport:
                if let jobNow {
                    if Self.ranSince(lastRunBefore, jobNow) { phase = .finished(result: Self.result(of: jobNow)); return }
                    if Self.isRunning(jobNow) { phase = .started; return }
                }
            default: break
            }
        }
        phase = .failed(Self.plainWords(error))
    }

    /// The confirmation has had its moment: Run now again, unless a newer run has begun. A
    /// failure stays until the next tap.
    mutating func settle(attempt: Int) {
        guard attempt == self.attempt else { return }
        switch phase {
        case .started, .finished: phase = .idle
        case .idle, .running, .failed: break
        }
    }

    // MARK: What the button shows

    var title: String {
        switch phase {
        case .idle, .failed: return "Run now"
        case .running: return "Running…"
        case .started: return "Started"
        case .finished: return "Finished"
        }
    }

    /// The button's symbol; nil while running, when it is a spinner.
    var symbol: String? {
        switch phase {
        case .idle, .failed: return "play.circle"
        case .running: return nil
        case .started: return "checkmark.circle"
        case .finished(let result): return result.map(Self.isGood) == false ? "exclamationmark.circle" : "checkmark.circle"
        }
    }

    /// The line under the button, and whether it is bad news.
    var note: (text: String, isProblem: Bool)? {
        switch phase {
        case .idle: return nil
        case .running: return ("The gateway is running it now. It carries on if you leave this page.", false)
        case .started: return ("Still running on the gateway. Last run changes when it is done.", false)
        case .finished(let result):
            guard let result else { return nil }
            return ("Last result: \(result).", !Self.isGood(result))
        case .failed(let message): return (message, true)
        }
    }

    // MARK: Reading the gateway

    /// Whether to ask the gateway about the job after this error: only when there was no answer
    /// at all, which may just mean the task is taking a while.
    static func mayStillBeRunning(after error: Error) -> Bool {
        if case .transport? = error as? HermesAPIError { return true }
        return false
    }

    /// The job has run since `before` (its last run when Run now was tapped).
    static func ranSince(_ before: String?, _ job: JSONValue) -> Bool {
        guard let now = job["last_run_at"]?.stringValue, !now.isEmpty else { return false }
        return now != before
    }

    /// A run in progress: the gateway's lease on the job while it runs, or the latest
    /// execution the job list carries.
    static func isRunning(_ job: JSONValue) -> Bool {
        if let claim = job["fire_claim"], !claim.isNull { return true }
        if let s = job["latest_execution"]?["status"]?.stringValue, ["claimed", "running"].contains(s) { return true }
        return job["state"]?.stringValue == "running"
    }

    /// The job's last status in words ("delivery_failed" reads "delivery failed").
    static func result(of job: JSONValue) -> String? {
        guard let s = job["last_status"]?.stringValue, !s.isEmpty else { return nil }
        return s.replacingOccurrences(of: "_", with: " ")
    }

    static func isGood(_ result: String) -> Bool {
        ["ok", "success", "succeeded", "completed", "done"].contains(result.lowercased())
    }

    /// What went wrong, for someone who does not read status codes.
    static func plainWords(_ error: Error) -> String {
        guard let e = error as? HermesAPIError else { return sentence(error.localizedDescription) }
        switch e {
        case .http(409, _):
            // The gateway's own guard: the task already holds a run (another tap, another
            // device, or its schedule).
            return "It is already running. Wait for it to finish, then try again."
        case .http(404, _):
            return "The gateway no longer has this task. Go back and refresh the list."
        case .http(let status, let detail):
            let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? "The gateway could not run it (error \(status))." : "The gateway could not run it: " + sentence(d)
        case .transport(let message):
            return "No answer from the gateway: " + sentence(message)
        default:
            return sentence(e.localizedDescription)
        }
    }

    private static func sentence(_ s: String) -> String {
        guard let last = s.last else { return s }
        return ".!?".contains(last) ? s : s + "."
    }
}

/// Runs in flight, by gateway and task, for as long as the app is open: back on a task's page
/// after leaving it mid-run, the button still says Running… and still sends nothing.
@MainActor @Observable final class CronRuns {
    static let shared = CronRuns()
    private(set) var runs: [String: CronRun] = [:]

    func run(_ key: String) -> CronRun { runs[key] ?? CronRun() }

    func update(_ key: String, _ change: (inout CronRun) -> Void) {
        var r = run(key)
        change(&r)
        runs[key] = r
    }
}
