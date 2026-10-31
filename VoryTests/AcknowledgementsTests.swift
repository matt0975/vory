import Foundation
import Testing
@testable import Vory

/// Settings › About › Acknowledgements reads its licences from the app bundle.
@Suite struct AcknowledgementsTests {

    /// The app carries KaTeX's notice first, word for word as KaTeX 0.16.11 ships it, and its fonts'
    /// second: their own notice and the SIL Open Font License 1.1 in full.
    @Test func theAppCarriesKaTeXsNotices() throws {
        let list = Acknowledgement.bundled()
        try #require(list.count == 2)
        let katex = list[0]
        #expect(katex.name == "KaTeX")
        #expect(katex.version == "0.16.11")
        #expect(katex.licence == "MIT License")
        #expect(katex.text.hasPrefix("The MIT License (MIT)\n\nCopyright (c) 2013-2020 Khan Academy and other contributors\n\n"))
        #expect(katex.text.contains("The above copyright notice and this permission notice shall be included in all\ncopies or substantial portions of the Software."))
        #expect(katex.text.hasSuffix("OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\nSOFTWARE."))

        let fonts = list[1]
        #expect(fonts.name == "KaTeX fonts")
        #expect(fonts.version == "0.16.11")
        #expect(fonts.licence == "SIL Open Font License 1.1")
        #expect(fonts.text.hasPrefix("""
            Copyright (c) 2009-2010, Design Science, Inc. (<www.mathjax.org>)
            Copyright (c) 2014-2018 Khan Academy (<www.khanacademy.org>),
            with Reserved Font Names KaTeX_AMS, KaTeX_Caligraphic, KaTeX_Fraktur, KaTeX_Main, KaTeX_Math, KaTeX_SansSerif, KaTeX_Script, KaTeX_Size1, KaTeX_Size2, KaTeX_Size3, KaTeX_Size4 and KaTeX_Typewriter.

            This Font Software is licensed under the SIL Open Font License, Version 1.1.
            """))
        #expect(fonts.text.contains("""
            SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
            -----------------------------------------------------------

            PREAMBLE
            The goals of the Open Font License (OFL) are to stimulate worldwide
            development of collaborative font projects,
            """))
        #expect(fonts.text.contains("""
            PERMISSION & CONDITIONS
            Permission is hereby granted, free of charge, to any person obtaining
            a copy of the Font Software, to use, study, copy, merge, embed, modify,
            redistribute, and sell modified and unmodified copies of the Font
            Software, subject to the following conditions:

            1) Neither the Font Software nor any of its individual components,
            in Original or Modified Versions, may be sold by itself.

            2) Original or Modified Versions of the Font Software may be bundled,
            redistributed and/or sold with any software, provided that each copy
            contains the above copyright notice and this license. These can be
            included either as stand-alone text files, human-readable headers or
            in the appropriate machine-readable metadata fields within text or
            binary files as long as those fields can be easily viewed by the user.

            3) No Modified Version of the Font Software may use the Reserved Font
            Name(s) unless explicit written permission is granted by the corresponding
            Copyright Holder. This restriction only applies to the primary font name as
            presented to the users.

            4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
            Software shall not be used to promote, endorse or advertise any
            Modified Version, except to acknowledge the contribution(s) of the
            Copyright Holder(s) and the Author(s) or with their explicit written
            permission.

            5) The Font Software, modified or unmodified, in part or in whole,
            must be distributed entirely under this license, and must not be
            distributed under any other license. The requirement for fonts to
            remain under this license does not apply to any document created
            using the Font Software.
            """))
        #expect(fonts.text.hasSuffix("""
            DISCLAIMER
            THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
            EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
            MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
            OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
            COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
            INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
            DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
            FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
            OTHER DEALINGS IN THE FONT SOFTWARE.
            """))
    }

    /// Both KaTeX entries name the KaTeX the app carries, by its script's own version, so an update of
    /// the bundled script can't leave a stale notice behind.
    @Test func theNoticesNameTheBundledKaTeX() throws {
        let script = KaTeXAssets.jsString
        let found = try #require(script.range(of: #"version:"[0-9.]+""#, options: .regularExpression))
        let version = String(script[found].dropFirst("version:\"".count).dropLast())
        #expect(version == "0.16.11")
        let list = Acknowledgement.bundled()
        try #require(list.count == 2)
        #expect(list.allSatisfy { $0.version == version })
    }

    /// Each notice reads as paragraphs that reflow at any text size, its headings on their own, and
    /// the joining loses no word; only the rules of dashes are left out.
    @Test func aNoticeReadsAsParagraphs() throws {
        let list = Acknowledgement.bundled()
        try #require(list.count == 2)
        #expect(list[0].paragraphs.count == 5)
        #expect(list[1].paragraphs.count == 23)
        #expect(list[1].paragraphs.contains("PREAMBLE"))
        #expect(list[1].paragraphs.contains("SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007"))
        let words = { (s: String) in s.split(whereSeparator: \.isWhitespace).map(String.init) }
        for item in list {
            #expect(item.paragraphs.allSatisfy { !$0.isEmpty && !$0.contains("\n") })
            let shown = item.text.split(separator: "\n").filter { !$0.allSatisfy { $0 == "-" } }.joined(separator: "\n")
            #expect(item.paragraphs.flatMap(words) == words(shown))
        }
    }
}
