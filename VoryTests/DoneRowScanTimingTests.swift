import Foundation
import Testing
@testable import VoryCore
@testable import Vory

/// What a finished reply's row costs to scan for what it names (#638): its pictures and files (one pass through the
/// sentences for both) and the bubble's words without the media, on one long technical reply, each timed 50 times.
/// Cold is the first draw of a reply (a fresh text each time, nothing kept); warm is every draw after it (the row's
/// scans kept by its text). A printed number, not a gate: a row evaluates its body often, and with a path in a
/// sentence it scans in full.
@Suite struct DoneRowScanTimingTests {
    /// About 400 lines and 25 KB: ten blocks of a heading, prose with three paths in sentences or inline code, a
    /// picture named in passing, a fenced command block with paths in it, a table, and a list of words that only
    /// look like paths.
    static func longReply() -> String {
        var lines: [String] = []
        for k in 1...10 {
            lines.append("## Shard \(k): what the nightly export checked")
            lines.append("")
            lines.append("The export for shard \(k) finished at 02:\(10 + k) and every row matched the source table, so nothing needed a retry.")
            lines.append("Its report is in /home/hermes/out/shard-\(k)/report-\(k).md, written after the last check had passed.")
            lines.append("The raw numbers are in `/home/hermes/out/shard-\(k)/numbers-\(k).csv` if you want to look at them yourself.")
            lines.append("The log (/home/hermes/out/shard-\(k)/run-\(k).log) has the timings for each of the forty batches.")
            lines.append("The chart of the batch times is /home/hermes/out/shard-\(k)/times-\(k).png, slowest batches on the right.")
            lines.append("")
            lines.append("```bash")
            lines.append("cat /home/hermes/out/shard-\(k)/report-\(k).md | head -40")
            lines.append("grep -c ERROR /var/log/export/shard-\(k).log")
            lines.append("rsync -av /srv/export/shard-\(k)/ /mnt/backup/shard-\(k)/")
            lines.append("python3 /opt/tools/verify.py --shard \(k) --strict")
            lines.append("```")
            lines.append("")
            lines.append("| batch | rows | errors | slowest ms |")
            lines.append("|---|---|---|---|")
            for b in 1...6 { lines.append("| \(b) | \(1000 * b + k) | \(b % 3) | \(200 + 13 * b + k) |") }
            lines.append("")
            lines.append("- The retry policy stays at three tries and/or a five minute wait, whichever comes first.")
            lines.append("- Use /help in the console for the flags; /new starts a fresh session for the next shard.")
            lines.append("- Version 1.2.\(k) of the exporter wrote these, and a / b in the table means rows over batches.")
            lines.append("- The folder /srv/export/shard-\(k)/ keeps the last seven nights, older ones are pruned.")
            lines.append("- Nothing was written under /var/log/export this time, and /usr/bin is unchanged.")
            lines.append("- See https://status.example.com/shards/\(k) for the dashboard and its history page.")
            for p in 1...9 {
                lines.append("Batch group \(p) of shard \(k) ran in order with no gaps, and its checksums matched the ones stored last night.")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    @Test func aDoneRowsScansAreTimed() {
        let text = Self.longReply()
        let clock = ContinuousClock()
        var cs: [Double] = [], cw: [Double] = [], cfull: [Double] = [], cd: [Double] = []
        var wi: [Double] = [], wf: [Double] = [], ww: [Double] = []
        var found = (0, 0)
        for run in 0..<50 {
            // Cold: a text never drawn before, nothing kept. The scans are the pictures and the files with one pass
            // through the sentences; the first draw is all a finished row works out the first time (scans and words).
            let fresh = text + "\n\nRun \(run) of the timing."
            cs.append(Self.ms(clock.measure { let both = TranscriptMedia.scanBoth(fresh); found = (both.images.count, both.files.count) }))
            cw.append(Self.ms(clock.measure { _ = MediaScan.textWithoutMedia(fresh) }))
            cfull.append(Self.ms(clock.measure { _ = MediaScan.textWithoutMedia(fresh, fast: false) }))
            cd.append(Self.ms(clock.measure { _ = TranscriptMedia.DoneScan(fresh) }))
        }
        // Warm: the same reply drawn again, as a done row is, once it has been drawn.
        _ = (TranscriptMedia.images(in: text), TranscriptMedia.files(in: text), TranscriptMedia.words(in: text))
        for _ in 0..<50 {
            wi.append(Self.ms(clock.measure { _ = TranscriptMedia.images(in: text) }))
            wf.append(Self.ms(clock.measure { _ = TranscriptMedia.files(in: text) }))
            ww.append(Self.ms(clock.measure { _ = TranscriptMedia.words(in: text) }))
        }
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let (s, w, full, d) = (Self.median(cs), Self.median(cw), Self.median(cfull), Self.median(cd))
        let (i2, f2, w2) = (Self.median(wi), Self.median(wf), Self.median(ww))
        print(String(format: "DONE-ROW-SCAN %@: %d bytes, %d lines; found %d pictures, %d files; median of 50 (ms) cold: scans %.3f (pictures and files, one pass through the sentences), words %.3f (every pass on every line %.3f), first draw %.3f; warm: images %.3f, files %.3f, words %.3f, all %.3f",
                     platform, text.utf8.count, text.split(separator: "\n", omittingEmptySubsequences: false).count, found.0, found.1,
                     s, w, full, d, i2, f2, w2, i2 + f2 + w2))
        #expect(text.utf8.count > 20_000)
        #expect(found.0 == 10 && found.1 == 30, "the reply names 10 pictures and 30 files in its sentences")
    }
}

/// The words' fast pass and the done row's kept scans (#638) give exactly what the full ones give.
@Suite struct DoneRowScanCacheTests {
    /// Every reply the media tests take the words of, the long one, and lines at the fast pass's edges.
    static let replies: [String] = [
        DoneRowScanTimingTests.longReply(),
        "Here is the chart you asked for.\nMEDIA:/home/hermes/.hermes/images/chart.png\nAnd the same as markdown: ![disk use](/home/hermes/.hermes/images/disk.jpg)\n/tmp/screens/after.webp\nNot this: ![remote](https://example.com/x.png) nor /etc/hosts nor MEDIA:/tmp/notes.txt",
        "Done. MEDIA:/home/hermes/out/report.pdf\nThe data: [raw numbers](</home/hermes/out/raw numbers.csv>) and the bundle [zip](/home/hermes/out/bundle.zip).\n/home/hermes/out/call.m4a\n~/clips/demo.mov\nAgain MEDIA:/home/hermes/out/report.pdf",
        "See MEDIA:/home/hermes/out/shot.png and ![plot](/home/hermes/out/plot.jpg).\nNothing was written under /var/log this time, and /usr/bin is on the path.\nA web file: [docs](https://example.com/guide.pdf) and a version like 1.2.3 or a/b.c in prose.",
        "The report is ready.\n\nMEDIA:/home/hermes/out/report.pdf\n\nThe numbers: [raw numbers](</home/hermes/out/raw numbers.csv>).\n/home/hermes/out/bundle.zip\nThat is all.",
        "Ready.\n\n`/home/hermes/out/call.m4a`\n\nThat is all.",
        "See /home/hermes/out/plan.md for the steps.\n\n`/home/hermes/out/summary.pdf`\n\nThat is all.",
        "Look:\n![before](/home/x/.hermes/images/a.png)\n![the chart](https://example.com/c.png)\nMEDIA:/home/x/.hermes/images/b.png",
        "Here:\r\n/tmp/shot.png.\r\nDone.",
        "\n## Done\n\n- **4.2 GB** freed\n- `rotate 8` set\n\n```bash\nlogrotate -f /etc/logrotate.conf\n```\n  ",
        "Here is the disk use before and after:\nMEDIA:/home/bot/charts/disk.png\nThat should hold.",
        "See /home/hermes/out/plan.md for the steps.\n\nMEDIA:/home/hermes/out/report.pdf\n`/home/hermes/out/call.m4a`",
        // The fast pass's edges: a bracket pair split across a line, "MEDIA" without its colon, a tilde alone,
        // blank and space-only lines, CRLF, and a link with no path.
        "A list] (not a link) and MEDIA without its colon.\n   \n\n\n~\nPlain words only.\r\n[a link](https://example.com) and ](\nMEDIA:\nEnd.",
    ]

    @Test func theFastWordsAreTheFullWords() {
        for reply in Self.replies {
            #expect(MediaScan.textWithoutMedia(reply, fast: true) == MediaScan.textWithoutMedia(reply, fast: false), "\(reply.prefix(60))")
        }
    }

    @Test func aDoneRowsKeptScansAreItsOwnAndTheScansAnswer() {
        for reply in Self.replies {
            let text = reply + "\n\nKept \(UUID().uuidString)."
            // Against the public scans called by themselves (each its own look through the sentences), gated as a
            // finished row gates them: not the shared pass the kept scans take.
            let m = TranscriptMedia.marks(in: text)
            let images = m.mediaOrPath || m.image || m.prosePath ? MediaScan.images(in: text, prose: m.prosePath) : []
            let files = m.mediaOrPath || m.link || m.prosePath ? MediaScan.files(in: text, prose: m.prosePath) : []
            #expect(TranscriptMedia.images(in: text) == images)
            #expect(TranscriptMedia.files(in: text) == files)
            #expect(TranscriptMedia.words(in: text) == MediaScan.textWithoutMedia(text, fast: false))
            #expect(TranscriptMedia.done(text) === TranscriptMedia.done(text), "the second draw takes the kept scans")
        }
        // Two texts a letter apart keep their own answers.
        let a = "See /home/hermes/out/a-\(UUID().uuidString).md now.", b = a.replacingOccurrences(of: "/a-", with: "/b-")
        #expect(TranscriptMedia.files(in: a).map(\.name) != TranscriptMedia.files(in: b).map(\.name))
        #expect(TranscriptMedia.files(in: a).first?.candidates.first?.contains("/a-") == true)
        #expect(TranscriptMedia.files(in: b).first?.candidates.first?.contains("/b-") == true)
        // A streaming row keeps nothing.
        let streaming = "See /home/hermes/out/s-\(UUID().uuidString).md now.\nMEDIA:/home/hermes/out/s.pdf"
        _ = (TranscriptMedia.images(in: streaming, streaming: true), TranscriptMedia.files(in: streaming, streaming: true),
             TranscriptMedia.words(in: streaming, streaming: true))
        #expect(TranscriptMedia.doneScans.object(forKey: streaming as NSString) == nil)
    }
}
