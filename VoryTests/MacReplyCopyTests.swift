#if os(macOS)
import Testing
@testable import Vory

/// #255: what Copy on a reply puts on the pasteboard.
struct MacReplyCopyTests {
    @Test func aPlainReplyIsCopiedAsItsMarkdownTrimmed() {
        let reply = "\n## Done\n\n- **4.2 GB** freed\n- `rotate 8` set\n\n```bash\nlogrotate -f /etc/logrotate.conf\n```\n  "
        #expect(TranscriptMedia.copyText(reply) == "## Done\n\n- **4.2 GB** freed\n- `rotate 8` set\n\n```bash\nlogrotate -f /etc/logrotate.conf\n```")
    }

    @Test func picturesLeaveTheCopyAsTheyLeaveTheBubble() {
        let reply = "Here is the disk use before and after:\nMEDIA:/home/bot/charts/disk.png\nThat should hold."
        let copied = TranscriptMedia.copyText(reply)
        #expect(!copied.contains("MEDIA:"))
        #expect(copied.contains("Here is the disk use before and after:"))
        #expect(copied.contains("That should hold."))
    }
}
#endif
