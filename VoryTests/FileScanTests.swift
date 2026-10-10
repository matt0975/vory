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
}
