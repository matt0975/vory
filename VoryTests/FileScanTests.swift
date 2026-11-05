import Foundation
import Testing
@testable import VoryCore

/// Files a reply names (#309): which paths become cards, and that the bubble's words lose
/// the lines while a link keeps its words.
@Suite struct FileScanTests {
    @Test func everyWayOfNamingAFileIsFoundOnce() {
        let text = """
        Done. MEDIA:/home/hermes/out/report.pdf
        The data: [raw numbers](</home/hermes/out/raw numbers.csv>) and the bundle [zip](/home/hermes/out/bundle.zip).
        /home/hermes/out/call.m4a
        ~/clips/demo.mov
        Again MEDIA:/home/hermes/out/report.pdf
        """
        let names = MediaScan.files(in: text).map(\.name)
        #expect(names == ["report.pdf", "raw numbers.csv", "bundle.zip", "call.m4a", "demo.mov"])
        let kinds = MediaScan.files(in: text).map { MediaScan.FileKind.of($0.name) }
        #expect(kinds == [.pdf, .table, .archive, .audio, .video])
        // The link's words name the card; the path with spaces is kept whole.
        #expect(MediaScan.files(in: text)[1].candidates == ["/home/hermes/out/raw numbers.csv"])
    }

    @Test func picturesAndLookalikesAreNotFiles() {
        let text = """
        See MEDIA:/home/hermes/out/shot.png and ![plot](/home/hermes/out/plot.jpg).
        Nothing was written under /var/log this time, and /usr/bin is on the path.
        A web file: [docs](https://example.com/guide.pdf) and a version like 1.2.3 or a/b.c in prose.
        """
        #expect(MediaScan.files(in: text).isEmpty)
        #expect(MediaScan.isFilePath("/var/log") == false)
        #expect(MediaScan.isFilePath("/home/hermes/out/") == false)
        #expect(MediaScan.isFilePath("/home/hermes/.hermes/config.yaml"))
        #expect(MediaScan.isFilePath("~/out/notes.md"))
        #expect(MediaScan.isFilePath("https://example.com/guide.pdf") == false)
    }

    @Test func theWordsLoseTheFileLinesAndALinkKeepsItsWords() {
        let text = "The report is ready.\n\nMEDIA:/home/hermes/out/report.pdf\n\nThe numbers: [raw numbers](</home/hermes/out/raw numbers.csv>).\n/home/hermes/out/bundle.zip\nThat is all."
        let words = MediaScan.textWithoutMedia(text)
        #expect(words == "The report is ready.\n\nThe numbers: raw numbers.\nThat is all.")
    }

    @Test func aPathInInlineCodeIsAFile() {
        let text = "Ready.\n\n`/home/hermes/out/call.m4a`\n\nThat is all."
        #expect(MediaScan.files(in: text).map(\.name) == ["call.m4a"])
        #expect(!MediaScan.textWithoutMedia(text).contains("call.m4a"))
    }

    // MARK: A file named in a sentence or in inline code (#638)

    @Test func aPathInASentenceOrInInlineCodeIsAFile() {
        let cases: [(String, [String])] = [
            ("See /home/hermes/out/plan.md for the steps.", ["plan.md"]),
            ("Saved to `/home/hermes/out/summary.pdf`.", ["summary.pdf"]),
            ("It is in `/home/hermes/out/My Plan.md` now.", ["My Plan.md"]),
            ("The copy is `/home/hermes/out/report.final copy.pdf` now.", ["report.final copy.pdf"]),
            ("Run `cat /home/hermes/out/a.md` to read it.", ["a.md"]),
            ("The log (/home/hermes/out/run.log) has it.", ["run.log"]),
            ("**/home/hermes/out/plan.md** is the one.", ["plan.md"]),
            ("Did you mean /home/hermes/out/plan.md?", ["plan.md"]),
            ("Wrote it to ~/out/notes.md just now.", ["notes.md"]),
        ]
        for (text, names) in cases {
            #expect(MediaScan.files(in: text).map(\.name) == names, "\(text)")
        }
        #expect(MediaScan.files(in: "It is in `/home/hermes/out/My Plan.md` now.").first?.candidates == ["/home/hermes/out/My Plan.md"])
    }

    @Test func slashWordsThatAreNotFilesAreNotCards() {
        let words = [
            "Nothing went to /var/log and /usr/bin is on the path.",
            "Type /help or /new, or ask in /r/swift.",
            "The Files tab calls /api/files/download for it.",
            "A web server sends /index.html first, then /v1.2 and /2026.11 in its notes.",
            "This and/or that, a/b.c in prose, and 1/2/2026.",
            "Relative ones: out/report.pdf and ./report.pdf.",
            "On the web: https://example.com/a/guide.pdf and //cdn.example.com/x/app.js.",
            "The folder /home/hermes/out/ is empty.",
            "Secrets live in /home/hermes/.env, as ever.",
            "A command:\n\n```\ncat /home/hermes/out/fenced.md | head\n```\n",
        ]
        for text in words {
            #expect(MediaScan.files(in: text).isEmpty, "\(text)")
            #expect(MediaScan.images(in: text).isEmpty, "\(text)")
        }
        // A code span with a space in its path is that one file, never also the word before the space.
        #expect(!MediaScan.files(in: "The copy is `/home/hermes/out/report.final copy.pdf` now.").map(\.name).contains("report.final"))
    }

    @Test func aFileNamedInSeveralPlacesIsOneCard() {
        let text = "See /home/hermes/out/plan.md, also `/home/hermes/out/plan.md`.\n/home/hermes/out/plan.md\nMEDIA:/home/hermes/out/plan.md"
        #expect(MediaScan.files(in: text).map(\.name) == ["plan.md"])
    }

    @Test func aPictureInASentenceIsAPictureNotAFile() {
        let text = "The chart is /home/hermes/out/chart.png and the shot is `/home/hermes/out/shot.jpg`."
        #expect(MediaScan.images(in: text).map(\.name) == ["chart.png", "shot.jpg"])
        #expect(MediaScan.files(in: text).isEmpty)
    }

    @Test func aSentenceKeepsItsPathInTheWords() {
        let text = "See /home/hermes/out/plan.md for the steps.\n\n`/home/hermes/out/summary.pdf`\n\nThat is all."
        #expect(MediaScan.textWithoutMedia(text) == "See /home/hermes/out/plan.md for the steps.\n\nThat is all.")
    }
}
