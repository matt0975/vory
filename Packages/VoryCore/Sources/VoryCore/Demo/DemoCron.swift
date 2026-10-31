import Foundation

/// The demo's scheduled tasks (#428's + on Scheduled Tasks): kept in memory for the demo's life, as its chat edits are,
/// so the + works there as it does on a gateway. A task made with the + is listed; its page's Save, Pause and Resume,
/// Run now and Delete act on it here. Nothing runs on a schedule: Run now marks the task run, now and "ok", as the
/// gateway answers once a run has ended. The demo starts with none, and all of them go when it ends.
extension DemoGateway {
    /// Where a task's result goes: saved on the gateway only (the demo has no messaging platforms).
    static var cronTargets: [[String: Any]] { [["id": "local", "name": "Local (save only)", "home_target_set": true, "home_env_var": NSNull()]] }

    /// The scheduled-task routes, as the gateway answers them (hermes_cli/web_routers/cron.py); nil for any other path.
    func cronRoute(method: String, path: String, query: [String: String], payload: [String: Any]) -> (Int, Any)? {
        if path == "/api/cron/delivery-targets" { return method == "GET" ? (200, ["targets": Self.cronTargets]) : notAllowed }
        guard path == "/api/cron/jobs" || path.hasPrefix("/api/cron/jobs/") else { return nil }
        if path == "/api/cron/jobs" {
            switch method {
            case "GET": return (200, ["jobs": cronJobs, "count": cronJobs.count])
            case "POST": return cronCreate(payload, bot: query["profile"])
            default: return notAllowed
            }
        }
        let parts = path.split(separator: "/").map(String.init)   // api, cron, jobs, <id>[, <action>]
        guard parts.count == 4 || parts.count == 5 else { return (404, ["detail": "Not Found"]) }
        let id = parts[3].removingPercentEncoding ?? parts[3]
        guard let i = cronJobs.firstIndex(where: { $0["job_id"] as? String == id }) else { return (404, ["detail": "Job not found"]) }
        if parts.count == 4 {
            switch method {
            case "GET":
                return (200, cronJobs[i])
            case "PUT":
                // The page's Save: the fields it changed, under "updates".
                for (k, v) in payload["updates"] as? [String: Any] ?? [:] where k != "job_id" && k != "id" { cronJobs[i][k] = v }
                if let p = cronJobs[i]["prompt"] as? String { cronJobs[i]["prompt_preview"] = String(p.prefix(120)) }
                return (200, cronJobs[i])
            case "DELETE":
                cronJobs.remove(at: i)
                return (200, ["ok": true])
            default:
                return notAllowed
            }
        }
        guard method == "POST" else { return notAllowed }
        switch parts[4] {
        case "pause": cronJobs[i]["enabled"] = false; cronJobs[i]["state"] = "paused"
        case "resume": cronJobs[i]["enabled"] = true; cronJobs[i]["state"] = "scheduled"
        case "trigger": cronJobs[i]["last_run_at"] = Self.isoNow(); cronJobs[i]["last_status"] = "ok"
        default: return (404, ["detail": "Not Found"])
        }
        return (200, cronJobs[i])
    }

    /// The + on Scheduled Tasks: a schedule is required (the gateway's 422 without one), the bot is the profile asked for.
    private func cronCreate(_ spec: [String: Any], bot: String?) -> (Int, Any) {
        let schedule = (spec["schedule"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !schedule.isEmpty else {
            return (422, ["detail": [["loc": ["body", "schedule"], "msg": "Field required", "type": "missing"]]])
        }
        let given = (spec["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = given.isEmpty ? "Task \(cronJobs.count + 1)" : given
        var id = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if id.isEmpty { id = "task-\(cronJobs.count + 1)" }
        while cronJobs.contains(where: { $0["job_id"] as? String == id }) { id += "-2" }
        let prompt = spec["prompt"] as? String ?? ""
        let deliver = (spec["deliver"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "local"
        let job: [String: Any] = ["job_id": id, "name": name, "schedule": schedule, "prompt": prompt,
                                  "prompt_preview": String(prompt.prefix(120)), "deliver": deliver, "enabled": true,
                                  "state": "scheduled", "profile": bot.flatMap { $0.isEmpty ? nil : $0 } ?? "default"]
        cronJobs.append(job)
        return (200, job)
    }

    private var notAllowed: (Int, Any) { (405, ["detail": "Method Not Allowed"]) }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
