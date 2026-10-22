import Testing
import VoryCore
@testable import Vory

/// The cheap look before a row's media scans (`TranscriptMedia.marks`): one pass over the bytes,
/// in place of eight `String.contains` per scan. It must let through everything the old look did.
@Suite struct TranscriptMediaMarksTests {
    @Test func plainTextHasNoMarks() {
        let m = TranscriptMedia.marks(in: "**Step 3.** The nightly export now writes to the backups disk.\n\nAll good.")
        #expect(!m.mediaOrPath && !m.image && !m.link)
        #expect(TranscriptMedia.images(in: "no pictures here").isEmpty)
        #expect(TranscriptMedia.files(in: "no files here").isEmpty)
    }

    @Test func mediaLinesAndPaths() {
        #expect(TranscriptMedia.marks(in: "The report.\n\nMEDIA:/home/hermes/out/report.pdf").mediaOrPath)
        #expect(TranscriptMedia.marks(in: "/var/log/app.log is the one").mediaOrPath)
        #expect(TranscriptMedia.marks(in: "~/notes.md").mediaOrPath)
        #expect(TranscriptMedia.marks(in: "Saved to\n/tmp/out.png").mediaOrPath)
        #expect(TranscriptMedia.marks(in: "Saved to\r\n/tmp/out.png").mediaOrPath)
        #expect(TranscriptMedia.marks(in: "Saved to\n~/out.png").mediaOrPath)
        #expect(TranscriptMedia.marks(in: "Saved to\r\n~/out.png").mediaOrPath)
        #expect(!TranscriptMedia.marks(in: "MEDIA").mediaOrPath)
        #expect(!TranscriptMedia.marks(in: "a / b and c ~ d").mediaOrPath)
    }

    @Test func aPathInInlineCodeEnablesTheScan() {
        let note = "Done.\n\n`/home/hermes/out/a.wav`\n\nThat is all."
        #expect(TranscriptMedia.marks(in: note).mediaOrPath)
        #expect(TranscriptMedia.files(in: note).map(\.name) == ["a.wav"])
        #expect(TranscriptMedia.files(in: "Done.\n\n`a.wav` and more words here\n").isEmpty)
    }

    @Test func imagesAndLinks() {
        let both = TranscriptMedia.marks(in: "Here: ![chart](/tmp/chart.png)")
        #expect(both.image && both.link)
        let link = TranscriptMedia.marks(in: "The numbers: [raw](</home/hermes/out/raw numbers.csv>).")
        #expect(link.link && !link.image)
        #expect(!TranscriptMedia.marks(in: "a ! [ b ] ( c").image)
    }

    @Test func theScansStillFindWhatTheyFound() {
        let text = "The report is ready.\n\nMEDIA:/home/hermes/out/report.pdf\n\nThe numbers behind it: [raw numbers](</home/hermes/out/raw numbers.csv>)."
        #expect(TranscriptMedia.files(in: text).count == MediaScan.files(in: text).count)
        #expect(!MediaScan.files(in: text).isEmpty)
        let pic = "Done.\n\n![chart](/tmp/chart.png)"
        #expect(TranscriptMedia.images(in: pic).count == MediaScan.images(in: pic).count)
        #expect(!MediaScan.images(in: pic).isEmpty)
    }
}
