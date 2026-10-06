import Foundation
import Testing
@testable import VoryCore

/// Pictures found in what a chat holds.
@Suite struct ChatMediaTests {
    @Test func aReplysMediaLinesMarkdownImagesAndBarePathsAreFound() {
        let reply = """
        Here is the chart you asked for.
        MEDIA:/home/hermes/.hermes/images/chart.png
        And the same as markdown: ![disk use](/home/hermes/.hermes/images/disk.jpg)
        /tmp/screens/after.webp
        Not this: ![remote](https://example.com/x.png) nor /etc/hosts nor MEDIA:/tmp/notes.txt
        """
        let refs = MediaScan.images(in: reply)
        #expect(refs.map(\.id) == ["/home/hermes/.hermes/images/chart.png", "/home/hermes/.hermes/images/disk.jpg", "/tmp/screens/after.webp"])
        #expect(refs[0].name == "chart.png")
        let prose = MediaScan.textWithoutMedia(reply)
        #expect(!prose.contains("MEDIA:") && !prose.contains("after.webp") && !prose.contains("disk.jpg"))
        #expect(prose.hasPrefix("Here is the chart you asked for.") && prose.contains("Not this: ![remote](https://example.com/x.png)"))
        #expect(prose.contains("And the same as markdown: disk use"))
    }

    @Test func aToolsOutputGivesUpItsImagePathsOnce() {
        let output = "Saved screenshot to '/Users/x/Pictures/shot 1.png' and /tmp/a.PNG, again /tmp/a.PNG; log at /var/log/x.log"
        let refs = MediaScan.imagePaths(inToolOutput: output)
        // A path with a space is not what a tool prints unquoted; the quoted one is cut at the space.
        #expect(refs.map(\.id) == ["/tmp/a.PNG"])
        #expect(MediaScan.imagePaths(inToolOutput: "path=/srv/out/render.jpeg").first?.id == "/srv/out/render.jpeg")
    }

    @Test func attachedImagesInAStoredUserRowAreNamedAndLookedForInTheProfilesImagesDir() {
        let text = "Look at this [User attached image: upload_20261004_093000_1.png] and [User attached image: upload_20261004_093000_2.jpg]"
        #expect(MediaScan.attachedImageNames(in: text) == ["upload_20261004_093000_1.png", "upload_20261004_093000_2.jpg"])
        #expect(MediaScan.userTextWithoutAttachments(text) == "Look at this and")
        let ref = MediaScan.attachedImageRef(name: "u.png", profile: "work")
        #expect(ref.candidates == ["~/.hermes/profiles/work/images/u.png", "~/.hermes/images/u.png", "~/.hermes/profiles/default/images/u.png"])
        #expect(ref.name == "u.png")
        #expect(MediaScan.attachedImageRef(name: "u.png", profile: "default").candidates.first == "~/.hermes/images/u.png")
    }

    @Test func theStoreKeysByGatewayAndPath() {
        #expect(MediaStore.key(gateway: "g1", path: "/a.png") != MediaStore.key(gateway: "g2", path: "/a.png"))
        #expect(MediaStore.key(gateway: "g1", path: "/a.png") == MediaStore.key(gateway: "g1", path: "/a.png"))
        #expect(MediaStore.key(gateway: "g", path: "/a").count == 32)
        #expect(MediaRef.isImage("/x/y.HEIC") && !MediaRef.isImage("/x/y.md"))
    }
}
