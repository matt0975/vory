import Foundation
import Testing
@testable import VoryCore

/// An attachment the gateway did not take: a missing tool on the gateway is said in plain words
/// (a tester's "attachments seem to be broken" was the gateway refusing PDFs for want of
/// poppler-utils); anything else is quoted as it came.
@Suite struct AttachmentRefusalTests {
    @Test func aGatewayWithoutThePDFToolsIsExplained() {
        let e = RPCError(code: -32000, message: "pdftoppm not installed (poppler-utils package required)")
        let text = ChatSession.attachmentFailure(name: "report.pdf", kind: .pdf, error: e)
        #expect(text.hasPrefix("Attachment report.pdf was not taken: the gateway is missing the tool it reads PDFs with"))
        #expect(text.contains("poppler-utils"))
        #expect(text.contains("Pictures and text files still go through"))
        #expect(text.hasSuffix("The gateway said: pdftoppm not installed (poppler-utils package required)"))
    }

    @Test func aMissingToolForAnotherKindIsExplainedToo() {
        let e = RPCError(code: -32000, message: "ffmpeg: command not found")
        let text = ChatSession.attachmentFailure(name: "clip.mov", kind: .video, error: e)
        #expect(text.hasPrefix("Attachment clip.mov was not taken: the gateway is missing a tool it needs for this kind of file"))
    }

    @Test func anyOtherRefusalIsQuotedAsItCame() {
        let e = RPCError(code: -32000, message: "file too large (max 20 MB)")
        let text = ChatSession.attachmentFailure(name: "big.pdf", kind: .pdf, error: e)
        #expect(text == "Attachment big.pdf failed: file too large (max 20 MB)")
    }
}
