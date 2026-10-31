import Foundation
import Testing
@testable import Vory

/// Settings › About › Acknowledgements reads its licences from the app bundle.
@Suite struct AcknowledgementsTests {

    /// The app carries KaTeX's notice, first in the list and word for word as KaTeX 0.16.11 ships it.
    @Test func theAppCarriesKaTeXsNoticeFirst() throws {
        let katex = try #require(Acknowledgement.bundled().first)
        #expect(katex.name == "KaTeX")
        #expect(katex.version == "0.16.11")
        #expect(katex.licence == "MIT License")
        #expect(katex.text.hasPrefix("The MIT License (MIT)\n\nCopyright (c) 2013-2020 Khan Academy and other contributors\n\n"))
        #expect(katex.text.contains("The above copyright notice and this permission notice shall be included in all\ncopies or substantial portions of the Software."))
        #expect(katex.text.hasSuffix("OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\nSOFTWARE."))
    }

    /// The notice reads as paragraphs that reflow at any text size, and the joining loses no word.
    @Test func aNoticeReadsAsParagraphs() throws {
        let katex = try #require(Acknowledgement.bundled().first)
        #expect(katex.paragraphs.count == 5)
        #expect(katex.paragraphs.allSatisfy { !$0.contains("\n") })
        let words = { (s: String) in s.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(katex.paragraphs.flatMap(words) == words(katex.text))
    }
}
