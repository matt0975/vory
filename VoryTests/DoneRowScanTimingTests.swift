import Foundation
import Testing
import VoryCore
@testable import Vory

/// What a finished reply's row costs to scan for what it names (#638): the picture scan, the file scan and the
/// bubble's words without the media, on one long technical reply, each timed 50 times. A printed number, not a
/// gate: a row evaluates its body often, and with a path in a sentence it now runs both scans in full.
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
        var images: [Double] = [], files: [Double] = [], words: [Double] = []
        var found = (0, 0, 0)
        for _ in 0..<50 {
            images.append(Self.ms(clock.measure { found.0 = TranscriptMedia.images(in: text).count }))
            files.append(Self.ms(clock.measure { found.1 = TranscriptMedia.files(in: text).count }))
            words.append(Self.ms(clock.measure { found.2 = MediaScan.textWithoutMedia(text).utf8.count }))
        }
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let (i, f, w) = (Self.median(images), Self.median(files), Self.median(words))
        print(String(format: "DONE-ROW-SCAN %@: %d bytes, %d lines; found %d pictures, %d files; median of 50 (ms): images %.3f, files %.3f, words %.3f, all %.3f",
                     platform, text.utf8.count, text.split(separator: "\n", omittingEmptySubsequences: false).count, found.0, found.1, i, f, w, i + f + w))
        #expect(text.utf8.count > 20_000)
    }
}
