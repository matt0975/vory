import Foundation
import Testing
@testable import VoryCore

/// #686: a picture named by its web address is the web's, not a file on the gateway. An image's address in a tool's raw
/// HTML showed a picture card for "//host/a/b.jpg", the address after "https:", and the gateway answered it with a 404.
/// Neither scan, a tool's output's or a reply's, takes a web address for a path; a path on the gateway is found as before.
@Suite struct WebImageAddressTests {
    @Test func aWebAddressIsNotAPictureOnTheGateway() {
        // In a tool's output: an address, one in an attribute with a query, and a protocol-relative one.
        #expect(MediaScan.imagePaths(inToolOutput: "https://host/a/b.jpg").map(\.id) == [])
        #expect(MediaScan.imagePaths(inToolOutput: "src=\"https://host/a/b.jpg?t=1\"").map(\.id) == [])
        #expect(MediaScan.imagePaths(inToolOutput: "//host/a/b.jpg").map(\.id) == [])
        // In a reply, the same three.
        #expect(MediaScan.images(in: "https://host/a/b.jpg").map(\.id) == [])
        #expect(MediaScan.images(in: "src=\"https://host/a/b.jpg?t=1\"").map(\.id) == [])
        #expect(MediaScan.images(in: "//host/a/b.jpg").map(\.id) == [])
    }

    @Test func aPathOnTheGatewayIsStillAPicture() {
        // In a tool's output: from the root, from the home, in quotes, after "=", in brackets, on a MEDIA: line and in a
        // markdown image.
        let cases = [("/tmp/a.png", "/tmp/a.png"), ("~/Pictures/b.jpg", "~/Pictures/b.jpg"), ("src=\"/tmp/c.png\"", "/tmp/c.png"),
                     ("out=/srv/e.jpeg", "/srv/e.jpeg"), ("saved (/tmp/f.webp)", "/tmp/f.webp"), ("MEDIA:/x/d.jpg", "/x/d.jpg"),
                     ("![shot](/tmp/g.png)", "/tmp/g.png")]
        for (text, path) in cases { #expect(MediaScan.imagePaths(inToolOutput: text).map(\.id) == [path], "\(text)") }
        // In a reply the same, but for the path after "=": a reply's scan doesn't look there, before #686 or after.
        for (text, path) in cases where !text.hasPrefix("out=") { #expect(MediaScan.images(in: text).map(\.id) == [path], "\(text)") }
    }

    @Test func aWebAddressInAReplyKeepsItsWords() {
        // A reply's words lose a line only to a card a scan draws. A protocol-relative picture is no card (above), so its
        // bare line stays as text, and its markdown stays for the parser, as a web image's with "https:" does; the fast
        // pass and the whole one (#638) alike.
        let bare = "//host/a/b.jpg", mark = "![x](//host/a/b.jpg)", web = "![x](https://host/a/b.jpg)"
        #expect(MediaScan.textWithoutMedia(bare) == bare)
        #expect(MediaScan.textWithoutMedia(bare, fast: false) == bare)
        #expect(MediaScan.textWithoutMedia(mark) == mark)
        #expect(MediaScan.textWithoutMedia(mark, fast: false) == mark)
        #expect(MediaScan.textWithoutMedia(web) == web)
        #expect(MediaScan.textWithoutMedia(web, fast: false) == web)
        // A file's bare line is a file card, "//" or not (files(in:), which #686 leaves as it is), so its line goes from
        // the words, as before.
        let file = "//cdn/x/app.js"
        #expect(MediaScan.files(in: file).map(\.id) == [file])
        #expect(MediaScan.textWithoutMedia(file) == "")
        #expect(MediaScan.textWithoutMedia(file, fast: false) == "")
    }
}
