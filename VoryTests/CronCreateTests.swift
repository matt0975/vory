import Foundation
import Testing
@testable import Vory

/// #428: Add scheduled task. The cron line the new-task form and a task's page both build from the pickers; which
/// answers to a create mean the gateway has no such route (the + goes); and when a refusal kept from before has gone
/// stale (the gateway's Hermes changed since).
@MainActor
struct CronCreateTests {
    private let nine30: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 30))!
    }()
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func thePickersBuildTheCronLine() {
        #expect(CronSchedule.build(kind: "daily", weekday: 1, monthDay: 1, time: nine30, calendar: utc) == "30 9 * * *")
        #expect(CronSchedule.build(kind: "weekdays", weekday: 1, monthDay: 1, time: nine30, calendar: utc) == "30 9 * * 1-5")
        #expect(CronSchedule.build(kind: "weekends", weekday: 1, monthDay: 1, time: nine30, calendar: utc) == "30 9 * * 0,6")
        #expect(CronSchedule.build(kind: "weekly", weekday: 3, monthDay: 1, time: nine30, calendar: utc) == "30 9 * * 3")
        #expect(CronSchedule.build(kind: "monthly", weekday: 1, monthDay: 15, time: nine30, calendar: utc) == "30 9 15 * *")
        // And it reads back the way the list words it.
        #expect(CronSchedule.describe(CronSchedule.build(kind: "weekdays", weekday: 1, monthDay: 1, time: nine30, calendar: utc)) == "Weekdays at 9:30 AM")
    }

    @Test func onlyAnUnknownRouteTakesThePlusAway() {
        #expect(CronCreateSupport.refusesRoute(status: 404))
        #expect(CronCreateSupport.refusesRoute(status: 405))
        // The task's own fault, a sign-in or a gateway trouble: the + stays, and the form says what went wrong.
        for status in [400, 401, 403, 422, 500, 502, 503] { #expect(!CronCreateSupport.refusesRoute(status: status), "\(status)") }
    }

    @Test func aRefusalLastsUntilTheGatewaysHermesChanges() {
        #expect(!CronCreateSupport.updatedSince(refusedAt: "0.21.4", now: "0.21.4"))
        #expect(CronCreateSupport.updatedSince(refusedAt: "0.21.4", now: "0.22.0"))
        // The version unknown now: the refusal stands.
        #expect(!CronCreateSupport.updatedSince(refusedAt: "0.21.4", now: nil))
        #expect(!CronCreateSupport.updatedSince(refusedAt: "0.21.4", now: ""))
        // Refused when the version couldn't be read: the first one known lets it go.
        #expect(CronCreateSupport.updatedSince(refusedAt: "", now: "0.21.4"))
    }
}
