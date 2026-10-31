import Foundation

/// What the demo shows (#392): its bots, chats, projects, files and board, in words Matt can
/// read and change here without touching the gateway's logic (`DemoGateway`). Generic people, places and
/// machines only, nothing that reads as a real person, no em dashes, and no links but the demo's own
/// (a picture is a `MEDIA:` path the demo itself serves). Times are offsets back from the moment the demo starts.
enum DemoContent {
    // MARK: Bots

    struct Bot: Sendable {
        let name: String        // the gateway's profile name (its folder)
        let display: String     // what Vory calls it
        let title: String       // its job, shown under the name
        let skills: Int
        /// Its look, as the Creator Studio makes one (`BotLookSpec`): a body shape, eyes and a colour. Shown only
        /// while the demo runs; never written to the looks that sync.
        let shape: String
        let eyes: String
        let hex: String
    }

    /// Four or five bots, each with a clear job. The first is the gateway's default bot.
    static let bots: [Bot] = [
        Bot(name: "default", display: "Sprout", title: "Research", skills: 14, shape: "drop", eyes: "classic", hex: "#30D158"),
        Bot(name: "gizmo", display: "Gizmo", title: "Home server", skills: 11, shape: "hexagon", eyes: "round", hex: "#FF9F0A"),
        Bot(name: "quill", display: "Quill", title: "Writing", skills: 8, shape: "pill", eyes: "sleepy", hex: "#BF5AF2"),
        Bot(name: "beacon", display: "Beacon", title: "Alerts", skills: 12, shape: "triangle", eyes: "wide", hex: "#FFD60A"),
        Bot(name: "pixel", display: "Pixel", title: "Design", skills: 9, shape: "square", eyes: "curious", hex: "#0A84FF"),
    ]

    static let model = "demo/assistant"
    static let fastModel = "demo/assistant-fast"
    static let provider = "demo"
    static let contextMax = 200_000
    static let home = "/home/demo"

    // MARK: Projects

    struct Project: Sendable {
        let id: String
        let slug: String
        let name: String
        let icon: String?
        let color: String
        let path: String
        let age: Double
    }

    static let projects: [Project] = [
        Project(id: "p_homelab", slug: "home-lab", name: "Home lab", icon: "server.rack", color: "hsl(210 70% 50%)", path: "/home/demo/homelab", age: 86_400 * 20),
        Project(id: "p_letter", slug: "newsletter", name: "Newsletter", icon: "pencil", color: "hsl(30 80% 50%)", path: "/home/demo/writing", age: 86_400 * 9),
        Project(id: "p_trip", slug: "lake-trip", name: "Lake trip", icon: "tent", color: "hsl(150 55% 42%)", path: "/home/demo/trip", age: 86_400 * 3),
    ]

    // MARK: Chats

    /// A message as `session.resume` lists it: `role` user, assistant or tool; a tool row has a `name` and
    /// a one-line `context`, and what it found in `text`.
    struct Row: Sendable {
        var role: String
        var text: String
        var name: String? = nil
        var context: String? = nil
        var reasoning: String? = nil
        /// Seconds after the chat's first message.
        var at: Double = 0
    }

    struct Chat: Sendable {
        let id: String
        let title: String
        let bot: String
        let preview: String
        let source: String
        let cwd: String
        let pinned: Bool
        /// How long ago it started and was last active.
        let started: Double
        let active: Double
        let rows: @Sendable () -> [Row]
    }

    static let longChatID = "20261012_070000_beacon"
    /// Every demo chat holds at most this many exchanges (a message and its reply), so it opens at its end in one go,
    /// with nothing older to load in under the reader (#491).
    static let maxExchanges = 4
    static let botChatID = "20261013_221000_gizmo1"

    static let chats: [Chat] = [
        Chat(id: "20261014_081500_sprout", title: "Packing list for the lake weekend", bot: "default",
             preview: "Here's a list for two nights by the lake, sorted by bag.", source: "ios", cwd: "/home/demo/trip",
             pinned: true, started: 5_400, active: 4_900, rows: { packingRows }),
        Chat(id: longChatID, title: "Morning checks on the home servers", bot: "beacon",
             preview: "All services up on nas-01; two package updates are waiting.", source: "cron", cwd: "/home/demo/homelab",
             pinned: false, started: Double(maxExchanges) * 900 + 600, active: 600, rows: { digestRows(rounds: maxExchanges) }),
        Chat(id: "20261013_203000_gizmo0", title: "Why is the NAS slow tonight?", bot: "gizmo",
             preview: "The nightly backup and a disk scrub started at the same time.", source: "ios", cwd: "/home/demo/homelab",
             pinned: false, started: 50_400, active: 49_200, rows: { nasRows }),
        Chat(id: "20261013_160000_quill1", title: "Newsletter intro, take two", bot: "quill",
             preview: "A warmer opening, and the three updates moved up front.", source: "ios", cwd: "/home/demo/writing",
             pinned: false, started: 66_000, active: 64_800, rows: { newsletterRows }),
        Chat(id: "20261012_190000_pixel1", title: "Compare three e-readers", bot: "default",
             preview: "The Inkwell 7 wins on battery, the Leaf Pro on the screen.", source: "ios", cwd: home,
             pinned: false, started: 140_000, active: 139_000, rows: { readerRows }),
        Chat(id: "20261013_110000_pixel2", title: "Colours for the garden sign", bot: "pixel",
             preview: "Leaf green, warm white and a marigold accent, easy to read from the street.", source: "ios", cwd: home,
             pinned: false, started: 100_000, active: 99_300, rows: { signRows }),
        Chat(id: botChatID, title: "Bot Chat", bot: "gizmo",
             preview: "Sounds good. I'll let you know when the backup's done.", source: "cli", cwd: "/home/demo/homelab",
             pinned: false, started: 90_000, active: 3_600, rows: { botChatRows }),
        Chat(id: "20261011_090000_sprout", title: "Weekly budget check-in", bot: "default",
             preview: "Groceries came in under plan, but the bike repair went over.", source: "cron", cwd: home,
             pinned: false, started: 260_000, active: 259_000, rows: { budgetRows }),
    ]

    // MARK: Histories

    static var packingRows: [Row] { [
        Row(role: "user", text: "We're heading to the lake for two nights. Can you make a packing list?"),
        Row(role: "assistant", text: """
            Here's a list for two nights by the lake, sorted by bag.

            ## Clothes
            - Two warm layers for the evenings (it drops to about 8 °C)
            - Rain jacket
            - Swimsuit and a quick-dry towel
            - Sandals and a pair of shoes for the trail

            ## Kitchen
            - Stove, fuel and a lighter
            - Two pots, a pan and a kettle
            - Coffee, oats, pasta and something for the grill

            ## Camp
            | Item | Who packs it | Done |
            |---|---|---|
            | Tent and pegs | Alex | yes |
            | Sleeping bags | Both | no |
            | Headlamps | Jamie | no |
            | First aid kit | Alex | yes |

            Want me to turn this into a checklist you can tick off on your phone?
            """, reasoning: "Two nights, a lake, probably cool evenings. Group by bag so it is easy to pack, and put shared gear in a table with who brings it.", at: 20),
        Row(role: "user", text: "Yes please, and add sunscreen.", at: 400),
        Row(role: "tool", text: "8 items added", name: "todo list", context: "add 8 items", at: 410),
        Row(role: "assistant", text: "Done. It's on your list with sunscreen added under Clothes. Have a great trip!", at: 420),
    ] }

    /// The long chat: a morning check each day (four of them, #491), each with its reasoning, three to five tool calls and
    /// a long digest (headings, a list, a table, a code block). The latest is nas-01's, with a chart, as the preview says.
    static func digestRows(rounds: Int) -> [Row] {
        let hosts = ["nas-01", "pi-kitchen", "media-box", "router", "printer", "backup-01"]
        let tools: [(String, String)] = [("terminal", "systemctl status --failed"), ("search files", "auth.log failed password"),
                                         ("read file", "/etc/fstab"), ("terminal", "df -h /srv"), ("terminal", "apt list --upgradable")]
        var out: [Row] = []
        for r in 0..<rounds {
            let t0 = Double(r) * 900
            let h = hosts[(rounds - 1 - r) % hosts.count]
            out.append(Row(role: "user", text: "Morning check on \(h). Anything I should know?", at: t0))
            out.append(Row(role: "assistant", text: "Looking at \(h) now.",
                           reasoning: "Start with the failed services on \(h), then the login attempts, then the disk, and compare with yesterday before writing it up.", at: t0 + 5))
            for k in 0..<(3 + r % 3) {
                let (name, ctx) = tools[(r + k) % tools.count]
                out.append(Row(role: "tool", text: k == 0 ? "0 failed units" : "done", name: name, context: ctx, at: t0 + 10 + Double(k)))
            }
            let chart = r == rounds - 1 ? "\n\nTraffic over the last day:\nMEDIA:/home/demo/images/traffic-\(h).png" : ""
            out.append(Row(role: "assistant", text: """
                ## Daily check: \(h)

                **Status:** all services up, \(2 + r % 5) warnings since yesterday, none new.

                ### What changed

                - Failed logins: \(12 + r * 2) from \(2 + r % 3) addresses, all blocked
                - Disk on `/srv` at \(48 + r % 30)%, up \(r % 3) points
                - Two package updates are waiting, neither marked urgent
                - The certificate on the reverse proxy renews in \(30 - r % 20) days

                ### Numbers

                | Check | Today | Yesterday | Trend |
                |---|---|---|---|
                | Requests | \(40 + r)k | \(39 + r)k | up |
                | Errors | \(r % 6) | \((r + 2) % 6) | flat |
                | p95 latency | \(120 + r % 30) ms | \(118 + r % 30) ms | flat |

                ### Next

                1. Apply the two updates in Thursday's window
                2. Keep an eye on the login count
                3. Nothing to do about the disk yet

                The commands I used:

                ```bash
                systemctl status --failed
                grep -c 'Failed password' /var/log/auth.log
                ```

                Say the word if you want the updates applied now.\(chart)
                """, at: t0 + 30))
        }
        return out
    }

    static var nasRows: [Row] { [
        Row(role: "user", text: "The NAS is really slow tonight. Copying photos takes forever. Can you check?"),
        Row(role: "assistant", text: "Checking the NAS now. I'll look at the load, the disks and anything scheduled.",
            reasoning: "Slow copies at night: likely a scheduled job. Check the load first, then what is running, then the disks and the network.", at: 4),
        Row(role: "tool", text: "load average: 6.12, 5.80, 4.95", name: "terminal", context: "uptime", at: 6),
        Row(role: "tool", text: "restic backup, 41% CPU; btrfs scrub, 33% CPU", name: "terminal", context: "ps -eo pid,comm,%cpu --sort=-%cpu | head", at: 8),
        Row(role: "tool", text: "scrub running on /srv, 62% done", name: "terminal", context: "btrfs scrub status /srv", at: 10),
        Row(role: "tool", text: "backup at 02:00 and scrub at 02:00", name: "read file", context: "/etc/cron.d/nas-jobs", at: 12),
        Row(role: "tool", text: "sda 98% busy, sdb 97% busy", name: "terminal", context: "iostat -x 1 3", at: 14),
        Row(role: "tool", text: "all disks PASSED", name: "terminal", context: "smartctl -H /dev/sda /dev/sdb", at: 16),
        Row(role: "tool", text: "940 Mbit/s", name: "terminal", context: "iperf3 -c nas-01 -t 5", at: 18),
        Row(role: "tool", text: "No errors in the last 24 h", name: "search files", context: "kernel log I/O error", at: 20),
        Row(role: "assistant", text: """
            Found it: the nightly backup and a disk scrub started at the same time, and both are reading every disk.

            | What | CPU | Started |
            |---|---|---|
            | Backup (restic) | 41% | 02:00 |
            | Disk scrub | 33% | 02:00 |

            The disks are healthy and the network is fine. They're just busy. The scrub is 62% done and should finish in about 40 minutes.

            To stop this happening again, I'd move the scrub to Sunday mornings:

            ```cron
            # /etc/cron.d/nas-jobs
            0 2 * * *   root  /usr/local/bin/backup.sh
            0 6 * * 0   root  btrfs scrub start /srv
            ```

            Want me to make that change?
            """, at: 30),
        Row(role: "user", text: "Yes, do it.", at: 600),
        Row(role: "tool", text: "1 line changed", name: "patch", context: "/etc/cron.d/nas-jobs", at: 605),
        Row(role: "assistant", text: "Done. The scrub now runs at 06:00 on Sundays. Tonight's will finish on its own.", at: 610),
    ] }

    static var newsletterRows: [Row] { [
        Row(role: "user", text: "Can you rewrite the intro of this month's newsletter? It feels flat. Here it is: \"This month we have some updates. Read on for details.\""),
        Row(role: "assistant", text: """
            Here's a warmer opening, with the three updates moved up front:

            > Hello again! October brought shorter days and a busy workshop. Three things we're excited about this month: the new evening classes, the community garden harvest, and a fresh look for our website.

            A few notes on the choices:
            - **Greeting first.** It reads like a letter, not a notice.
            - **The season.** One line of scene setting gives it a feeling of now.
            - **The three updates in one sentence,** so a reader who stops there still knows what's new.

            Want a shorter version for the email preview line too?
            """, reasoning: "The original says nothing. Make it personal, name the season, and surface the three updates so the intro does real work.", at: 30),
        Row(role: "user", text: "Love it. Yes, a preview line please.", at: 900),
        Row(role: "assistant", text: "Preview line: \"Evening classes, a garden harvest and a new website, all in this month's letter.\"", at: 910),
    ] }

    static var readerRows: [Row] { [
        Row(role: "user", text: "I want an e-reader for travel. Compare the Inkwell 7, the Leaf Pro and the Pageturner Go."),
        Row(role: "tool", text: "3 sources", name: "web search", context: "Inkwell 7 Leaf Pro Pageturner Go review", at: 5),
        Row(role: "tool", text: "spec sheets read", name: "web extract", context: "e-reader spec sheets", at: 9),
        Row(role: "assistant", text: """
            Here's how they compare for travel:

            | | Inkwell 7 | Leaf Pro | Pageturner Go |
            |---|---|---|---|
            | Screen | 7 in, 300 ppi | 7 in, 330 ppi | 6 in, 300 ppi |
            | Battery | 8 weeks | 5 weeks | 6 weeks |
            | Weight | 210 g | 235 g | 175 g |
            | Waterproof | yes | yes | no |
            | Price | 149 | 199 | 109 |

            Battery life, side by side:
            MEDIA:/home/demo/images/ereader-battery.png

            **My pick for travel: the Inkwell 7.** It lasts longest, it's waterproof and it's light enough for any bag. The Leaf Pro has the sharpest screen if that matters more to you. The Pageturner Go is the one to get on a budget, but keep it away from the pool.
            """, reasoning: "Travel means battery, weight and water matter most. Put the specs in one table, show battery as a chart, and make a clear pick.", at: 20),
    ] }

    static var signRows: [Row] { [
        Row(role: "user", text: "The community garden needs a sign for the gate. Can you suggest colours and a font that feel friendly?"),
        Row(role: "assistant", text: """
            Here's a palette that holds up outdoors and reads from a distance:

            | Use | Colour | Hex |
            |---|---|---|
            | Background | Leaf green | #3F7D4E |
            | Lettering | Warm white | #F7F3E8 |
            | Accent | Marigold | #F2A93B |

            For the lettering, a rounded sans serif in bold. On a 60 cm board, set the name about 12 cm tall and it stays readable from the street.

            Want a second option in blues, in case green blends into the hedge?
            """, reasoning: "An outdoor sign needs strong contrast, colours that suit a garden, and letters big enough to read from a few metres away.", at: 40),
        Row(role: "user", text: "Green's perfect. Leaf green and marigold it is.", at: 640),
        Row(role: "assistant", text: "Great choice. I'll keep the hex codes handy for when you order it.", at: 700),
    ] }

    static var botChatRows: [Row] { [
        Row(role: "user", text: "Message from \u{1F916} Beacon (@beacon): Heads up, there's a NAS firmware update waiting. I'd like to apply it tonight."),
        Row(role: "assistant", text: "Thanks. Tonight works, but only after the backup finishes, usually around 03:00.", at: 30),
        Row(role: "user", text: "Message from \u{1F916} Beacon (@beacon): Understood. I'll hold the update until the backup is done and check in the morning.", at: 86_000),
        Row(role: "assistant", text: "Sounds good. I'll let you know when the backup's done.", at: 86_400),
    ] }

    static var budgetRows: [Row] { [
        Row(role: "user", text: "Weekly budget check-in."),
        Row(role: "tool", text: "24 rows", name: "read file", context: "/home/demo/budget/october.csv", at: 4),
        Row(role: "assistant", text: """
            This week's spending against the plan:

            | Category | Plan | Spent | |
            |---|---|---|---|
            | Groceries | 120 | 104 | under |
            | Transport | 40 | 38 | on plan |
            | Eating out | 60 | 71 | over |
            | Bike repair | 30 | 55 | over |

            Groceries came in under plan, but the bike repair went over. You're 18 over in total, and next week's lighter plan covers it.
            """, at: 15),
    ] }

    // MARK: A new message's reply

    /// A scripted turn: what a message gets back, streamed at a believable pace. The onboarding tour (#388) plays the
    /// same turns, so the tour and "Try a demo" can't drift apart: change a turn here and both change.
    struct Turn: Sendable {
        struct Step: Sendable {
            let name: String        // the tool, as the card names it
            let context: String     // what it ran, shown on the card
            let summary: String     // the card's one line once it's done
            let output: String      // what opening the card shows
            /// How long it reports it took ("Ran a command · du -sh * (0.4 s)"); nil for the demo's own pace.
            var seconds: Double? = nil
        }
        /// The one thing a turn asks before it does it: the card's command and description, the words around it, and
        /// the step it runs when approved.
        struct Approval: Sendable {
            let ask: String
            let command: String
            let description: String
            let ran: Step
            let done: String
            let denied: String
        }
        let reasoning: String
        let opening: String
        let steps: [Step]
        /// Asked once per demo (`DemoGateway.approvalDue`); with it, `done` or `denied` ends the turn instead of `closing`.
        let approval: Approval?
        let closing: String
    }

    /// Any message: a look at two things, then an answer.
    static let everyday = Turn(
        reasoning: "Thinking about what would help most here.",
        opening: "Let me take a quick look before I answer.",
        steps: [
            .init(name: "search files", context: "notes about this", summary: "3 notes found", output: "notes/ideas.md\nnotes/todo.md\nnotes/2026-10.md\n"),
            .init(name: "terminal", context: "date && uptime", summary: "ok", output: "Tue Oct 14 10:02:11 UTC 2026\n up 12 days, 3 users, load average: 0.21, 0.30, 0.28\n"),
        ],
        approval: nil,
        closing: """
            Here's what I found:

            - Your notes mention this twice, both from this month
            - Nothing on the calendar clashes with it
            - The machine I checked is quiet, so now is a good time

            Want me to set a reminder, or draft the next step?
            """)

    /// A message that asks what's taking the space, or to clean up (or a new chat's second message): it measures, then
    /// asks once before it deletes anything. Onboarding's beats 3 and 4, Option A as Matt approved it: the ready-made
    /// message is "What's taking up the most space on my server?".
    static let cleanup = Turn(
        reasoning: "Measure first, then ask before deleting anything.",
        opening: "",
        steps: [
            .init(name: "terminal", context: "du -sh *", summary: "5 folders, 6.1 GB",
                  output: "4.2G\tlogs\n1.1G\tbackups\n640M\tmedia\n120M\tapp\n12M\tconfig\n", seconds: 0.4),
        ],
        approval: .init(
            ask: "Your logs folder is the big one, at 4.2 GB. Most of it is older than a month. Want me to clear out logs over 30 days old?",
            command: "find ./logs -mtime +30 -delete",
            description: "Delete the logs older than 30 days (3.1 GB)",
            ran: .init(name: "terminal", context: "find ./logs -mtime +30 -delete", summary: "3.1 GB freed", output: "", seconds: 1.8),
            done: "Done. I cleared 3.1 GB.",
            denied: "Understood, I'll leave the logs alone."),
        closing: "")

    // MARK: Group chat

    static let groupName = "Weekend projects"
    static let groupMembers = ["gizmo", "quill"]
    static let groupLog: [(who: String, text: String, ago: Double)] = [
        ("user", "Can you two plan the shed shelves for Saturday?", 7_200),
        ("gizmo", "I'll work out the measurements and a cut list from the shed's floor plan.", 7_180),
        ("quill", "And I'll write it up as a one-page plan with a shopping list.", 7_160),
        ("gizmo", "Cut list: four 1.8 m uprights, eight 90 cm shelves, and a box of 50 mm screws.", 7_000),
        ("quill", "The plan is in your Files as shed-shelves.md. It's about a morning's work.", 6_900),
    ]

    // MARK: Files

    struct File: Sendable {
        let path: String
        let directory: Bool
        let mime: String?
        let text: String?
        let age: Double
    }

    static let files: [File] = [
        File(path: "/home/demo/homelab", directory: true, mime: nil, text: nil, age: 3_600),
        File(path: "/home/demo/writing", directory: true, mime: nil, text: nil, age: 70_000),
        File(path: "/home/demo/trip", directory: true, mime: nil, text: nil, age: 5_000),
        File(path: "/home/demo/README.md", directory: false, mime: "text/markdown", text: """
            # Demo home

            This is the demo gateway's home folder. Everything here is made up for the demo,
            and nothing you change is kept.
            """, age: 900_000),
        File(path: "/home/demo/shed-shelves.md", directory: false, mime: "text/markdown", text: """
            # Shed shelves, Saturday

            ## Cut list
            - 4 uprights, 1.8 m
            - 8 shelves, 90 cm

            ## Shopping
            - Box of 50 mm screws
            - Wall plugs
            """, age: 6_900),
        File(path: "/home/demo/homelab/backup.sh", directory: false, mime: "text/x-shellscript", text: """
            #!/bin/sh
            # Nightly backup of /srv to the backup disk.
            restic -r /mnt/backup backup /srv --exclude-caches
            restic -r /mnt/backup forget --keep-daily 7 --keep-weekly 4 --prune
            """, age: 400_000),
        File(path: "/home/demo/homelab/temps.csv", directory: false, mime: "text/csv", text: """
            time,cpu_c,disk_c
            00:00,41,34
            06:00,39,33
            12:00,47,36
            18:00,45,35
            """, age: 3_600),
        File(path: "/home/demo/writing/october-letter.md", directory: false, mime: "text/markdown", text: """
            Hello again! October brought shorter days and a busy workshop.
            """, age: 64_800),
        File(path: "/home/demo/trip/packing.md", directory: false, mime: "text/markdown", text: """
            - Tent and pegs
            - Sleeping bags
            - Headlamps
            - Sunscreen
            """, age: 4_900),
    ]

    // MARK: The board

    struct BoardTask: Sendable {
        let id: String
        let title: String
        let status: String
        let assignee: String?
        let body: String?
        let summary: String?
        let age: Double
        let priority: Int
    }

    static let tasks: [BoardTask] = [
        BoardTask(id: "t-101", title: "Move the disk scrub to Sundays", status: "done", assignee: "gizmo", body: "It clashed with the nightly backup.",
             summary: "Scrub now runs at 06:00 on Sundays.", age: 50_000, priority: 1),
        BoardTask(id: "t-102", title: "Apply the NAS firmware update", status: "blocked", assignee: "beacon", body: "Wait until the backup is done.",
             summary: "Waiting for the backup to finish.", age: 86_000, priority: 1),
        BoardTask(id: "t-103", title: "Write October's newsletter", status: "review", assignee: "quill", body: "Intro done; three updates to fill in.",
             summary: "Draft ready for a read.", age: 66_000, priority: 0),
        BoardTask(id: "t-104", title: "Plan the shed shelves", status: "done", assignee: "gizmo", body: nil,
             summary: "Cut list and shopping list in Files.", age: 7_000, priority: 0),
        BoardTask(id: "t-105", title: "Renew the reverse proxy certificate", status: "todo", assignee: "beacon", body: "Expires in three weeks.",
             summary: nil, age: 30_000, priority: 2),
        BoardTask(id: "t-106", title: "Mock up the garden sign", status: "ready", assignee: "pixel", body: "Leaf green and marigold, name about 12 cm tall.",
             summary: nil, age: 20_000, priority: 0),
        BoardTask(id: "t-107", title: "Compare travel e-readers", status: "done", assignee: "default", body: nil,
             summary: "Inkwell 7 for travel.", age: 139_000, priority: 0),
        BoardTask(id: "t-108", title: "Sort the lake trip photos", status: "triage", assignee: nil, body: "After the weekend.",
             summary: nil, age: 1_800, priority: 0),
        BoardTask(id: "t-109", title: "Back up the router config", status: "running", assignee: "beacon", body: "Export the config and store it with the others.",
             summary: "Exporting the config.", age: 900, priority: 0),
    ]

    // MARK: Skills and tools

    static let skills: [(name: String, description: String, category: String, usage: Int)] = [
        ("trip-planner", "Plan a trip day by day, with a packing list", "life", 6),
        ("newsletter", "Draft and tidy a newsletter", "writing", 11),
        ("home-lab-check", "Check the home servers and write a digest", "beacon", 25),
        ("budget", "Compare spending with the plan", "life", 4),
        ("palette", "Suggest colours and type for a design", "design", 3),
    ]
}
