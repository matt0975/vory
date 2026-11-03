import Foundation
import Testing
@testable import VoryCore
@testable import Vory

/// Audit of the inline LaTeX path: what prose must survive untouched, what LaTeX must
/// render, and what the parser must not do twice (cost). Each test below was a real
/// defect reproduced against the engine before it was fixed.
@Suite struct InlineMathAuditTests {

    // MARK: - Prose must never be mangled by the math formatter

    @Test func proseBracesSurviveAlongsideNakedCommands() {
        let attr = MarkdownParser.inline("The set {a, b} has \\alpha in it.")
        let out = String(attr.characters)
        #expect(out.contains("{a, b}"))
        #expect(out.contains("α"))
    }

    @Test func proseObjectLiteralSurvives() {
        let attr = MarkdownParser.inline("Send {name: bob} to $x^2$ please.")
        #expect(String(attr.characters).contains("{name: bob}"))
    }

    @Test func unknownNakedCommandKeepsItsBraces() {
        let attr = MarkdownParser.inline("uses \\foobar{1} here")
        #expect(String(attr.characters) == "uses \\foobar{1} here")
    }

    @Test func nakedTextFamilyCommandsUnwrap() {
        #expect(String(MarkdownParser.inline("the \\textbf{bold} word").characters) == "the bold word")
        #expect(String(MarkdownParser.inline("the \\emph{one} word").characters) == "the one word")
        #expect(String(MarkdownParser.inline("the \\textsc{ab} word").characters) == "the ab word")
    }

    @Test func snakeCaseAndPathsSurviveNextToMath() {
        let out = String(MarkdownParser.inline("a_variable_name and C:\\Users\\andrew\\f.txt with $x_i$").characters)
        #expect(out.contains("a_variable_name"))
        #expect(out.contains("C:\\Users\\andrew\\f.txt"))
        #expect(out.contains("xᵢ"))
    }

    // MARK: - Inline code is literal

    @Test func mathInsideInlineCodeIsNotTouched() {
        let attr = MarkdownParser.inline("Use `$x_1$` and then $y_2$ here.")
        let out = String(attr.characters)
        #expect(out.contains("$x_1$"))
        #expect(out.contains("y₂"))
        // The code run must not have gained a math attribute.
        for run in attr.runs where String(attr[run.range].characters).contains("$x_1$") {
            #expect(run.math == nil)
        }
    }

    @Test func doubleBacktickCodeSpanIsLiteral() {
        #expect(String(MarkdownParser.inline("Use ``$x$`` here.").characters) == "Use $x$ here.")
    }

    @Test func parenthesisedMathInsideInlineCodeIsNotTouched() {
        let out = String(MarkdownParser.inline("Use `\\(x\\)` or `$PATH` in the shell.").characters)
        #expect(out.contains("\\(x\\)"))
        #expect(out.contains("$PATH"))
    }

    @Test func findInlineMathSkipsCodeSpans() {
        let spans = MathNotation.findInlineMath(in: "a `$x$` b $y$ c")
        #expect(spans.count == 1)
        #expect(spans.first?.equation == "y")
    }

    // MARK: - Delimiters

    @Test func displayDelimitersMidParagraphStillRender() {
        let attr = MarkdownParser.inline("So we get $$E = mc^2$$ which is nice.")
        let out = String(attr.characters)
        #expect(out == "So we get E = mc² which is nice.")
    }

    @Test func bracketDelimitersMidParagraphStillRender() {
        let attr = MarkdownParser.inline("We get \\[E = mc^2\\] and more.")
        let out = String(attr.characters)
        #expect(out == "We get E = mc² and more.")
    }

    @Test func spanDelimitersAreReported() {
        let spans = MathNotation.findInlineMath(in: "a $x$ b $$y$$ c \\(z\\) d \\[w\\]")
        #expect(spans.map(\.equation) == ["x", "y", "z", "w"])
        #expect(spans.map(\.isDisplay) == [false, true, false, true])
        #expect(spans.map(\.isDelimitedWithParentheses) == [false, false, true, false])
    }

    @Test func currencyIsStillNotMath() {
        #expect(String(MarkdownParser.inline("It costs $5 to $10 total.").characters) == "It costs $5 to $10 total.")
        #expect(MathNotation.findInlineMath(in: "pay $12.50 now").isEmpty)
    }

    // MARK: - Superscripts

    @Test func superscriptParenthesesAreGroupingNotGlyphs() {
        // The brackets group the body; they are not drawn. The old path emitted "x⁽n+1)".
        #expect(MathNotation.format("x^(n+1)") == "xⁿ⁺¹")
        #expect(MathNotation.format("a^(2)") == "a²")
        // A body with no Unicode superscripts falls back to the caret form, still balanced.
        #expect(MathNotation.format("x^(ab+1)") == "x^(ab+1)")
        #expect(MathNotation.format("x^{ab+1}") == "x^(ab+1)")
    }

    @Test func scriptAfterSpaceIsRead() {
        #expect(MathNotation.format("x_ 1") == "x₁")
        #expect(MathNotation.format("y^ 2") == "y²")
    }

    // MARK: - Commands the models actually emit

    @Test func escapedPercentBecomesPercent() {
        #expect(MathNotation.format("50\\%") == "50%")
        #expect(String(MarkdownParser.inline("Growth was $50\\%$ up.").characters) == "Growth was 50% up.")
    }

    @Test func accentsAndOverlines() {
        #expect(MathNotation.format("\\vec{F}") == "F\u{20D7}")
        #expect(MathNotation.format("\\bar{x}") == "x\u{0304}")
        #expect(MathNotation.format("\\overline{AB}") == "A\u{0305}B\u{0305}")
        #expect(MathNotation.format("\\hat{y}") == "y\u{0302}")
        #expect(MathNotation.format("\\underline{x}") == "x\u{0332}")
        #expect(!MathNotation.format("\\vec{F}").contains("\\vec"))
    }

    @Test func indexedSquareRoot() {
        #expect(MathNotation.format("\\sqrt[3]{x}") == "∛(x)")
        #expect(MathNotation.format("\\sqrt[4]{x}") == "∜(x)")
        #expect(MathNotation.format("\\sqrt[n]{x}") == "√[n](x)")
        #expect(MathNotation.format("\\sqrt{\\pi}") == "√(π)")
        #expect(MathNotation.format("\\sqrt{a + b}") == "√(a + b)")
    }

    @Test func implicitFractionArguments() {
        #expect(MathNotation.format("\\frac12") == "1/2")
        #expect(MathNotation.format("\\frac{a}{b}") == "a/b")
    }

    @Test func binomial() {
        #expect(MathNotation.format("\\binom{n}{k}") == "C(n, k)")
    }

    @Test func nestedFractionKeepsGrouping() {
        #expect(MathNotation.format("\\frac{a}{\\frac{b}{c}}") == "a/(b/c)")
        #expect(MathNotation.format("\\frac{1}{2}") == "1/2")
    }

    @Test func bracketCommands() {
        #expect(MathNotation.format("\\langle x, y \\rangle") == "⟨x, y⟩")
        #expect(MathNotation.format("\\lvert x \\rvert") == "|x|")
        #expect(MathNotation.format("\\lceil x \\rceil") == "⌈x⌉")
        #expect(MathNotation.format("\\lfloor x \\rfloor") == "⌊x⌋")
    }

    @Test func relationAndArrowCoverage() {
        #expect(MathNotation.format("A \\vdash B") == "A ⊢ B")
        #expect(MathNotation.format("A \\models B") == "A ⊨ B")
        #expect(MathNotation.format("a \\ll b \\gg c") == "a ≪ b ≫ c")
        #expect(MathNotation.format("A \\longrightarrow B") == "A ⟶ B")
    }

    @Test func environmentsBecomeReadableProse() {
        let out = MathNotation.format("\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}")
        #expect(!out.contains("\\begin"))
        #expect(!out.contains("\\end"))
        #expect(out.contains("1"))
    }


    // MARK: - Words that ran together (the "merged" bug)

    @Test func operatorNamesKeepTheirDistance() {
        // n\log n was rendered "nlog n" — the operator took its operand's space.
        #expect(MathNotation.format("n\\log n") == "n log n")
        #expect(MathNotation.format("O(n\\log n)") == "O(n log n)")
        #expect(MathNotation.format("y\\log p") == "y log p")
        // Two operators in a row take a thin space, as TeX spaces them.
        #expect(MathNotation.format("\\arg\\max_\\theta") == "arg\u{2009}max₍θ₎")
        // \log\frac{p}{q}: the fraction is the operator's argument, not more name.
        #expect(MathNotation.format("\\log\\frac{p}{q}") == "log\u{2009}p/q")
        #expect(!MathNotation.format("\\log\\frac{p}{q}").contains("\\"))
    }

    @Test func aCommandIsNotGluedIntoAnEarlierSubstitution() {
        // \eta\mathbf{g} came out as "\etag": the text command was unwrapped first.
        #expect(MathNotation.format("\\eta\\mathbf{g}") == "ηg")
        #expect(MathNotation.format("\\nabla_\\theta\\mathcal{L}") == "∇₍θ₎ℒ")
        // A name ends at ASCII: an inserted ℒ must not be read as part of "\thetaℒ".
        #expect(!MathNotation.format("\\theta\\mathcal{L}").contains("\\"))
    }

    @Test func relationsAreSpacedAndSignsAreNot() {
        #expect(MathNotation.format("x=1") == "x = 1")
        #expect(MathNotation.format("1\\le x\\le 2") == "1 ≤ x ≤ 2")
        #expect(MathNotation.format("x\\in A") == "x ∈ A")
        #expect(MathNotation.format("P(A\\mid B)") == "P(A | B)")
        // A sign with nothing before it stays attached.
        #expect(MathNotation.format("e^{-x^2}") == "e^(-x²)")
        #expect(MathNotation.format("a+-b") == "a+-b")
    }

    @Test func doubleBarNormIsRead() {
        #expect(MathNotation.format("\\|x\\|_2") == "‖x‖₂")
        #expect(MathNotation.format("\\lVert x \\rVert_1") == "‖x‖₁")
    }

    @Test func aSingleUnmappableScriptNeverLeavesItsMarker() {
        // ∇_\theta rendered a bare underscore, which reads as markdown emphasis.
        #expect(MathNotation.format("\\nabla_\\theta") == "∇₍θ₎")
        #expect(MathNotation.format("x_q") == "x₍q₎")
        #expect(!MathNotation.format("\\nabla_\\theta").contains("_"))
    }

    @Test func layoutCommandsDrawNothing() {
        #expect(MathNotation.format("\\overset{def}{=}") == "=")
        #expect(MathNotation.format("\\boxed{x}^2") == "x²")
        #expect(MathNotation.format("\\tag{1} x+y") == "x+y")
        #expect(MathNotation.format("a \\\\ b") == "a ; b")
        #expect(MathNotation.format("\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}") == "1 , 0 ; 0 , 1")
    }

    @Test func aDelimitedNumberIsMathsNotACurrency() {
        // "$1$" used to be vetoed as a price and shown with its dollars.
        #expect(String(MarkdownParser.inline("cost $1$ here").characters) == "cost 1 here")
        // A money-shaped amount still is not maths.
        #expect(String(MarkdownParser.inline("pay $12.50 now").characters) == "pay $12.50 now")
    }


    // MARK: - A script is drawn as a script

    @Test func aFallbackScriptIsSegmentedForDisplay() {
        // (ℳ_grass, g_μν): neither body has a Unicode subscript form, so it is written with the
        // fallback brackets for copy, and the view draws the body below the baseline.
        let formatted = MathNotation.format("(\\mathcal{M}_{\\text{grass}}, g_{\\mu\\nu})")
        #expect(formatted == "(ℳ₍grass₎, g₍μν₎)")
        let segments = MathNotation.segments(of: formatted)
        #expect(segments.map(\.text) == ["(ℳ", "grass", ", g", "μν", ")"])
        #expect(segments.map(\.script) == [.baseline, .sub, .baseline, .sub, .baseline])
    }

    @Test func mappableScriptsStayOnTheBaseline() {
        #expect(MathNotation.segments(of: "x₁ + mc²").count == 1)
    }

    @Test func aSuperscriptBodyKeepsItsOwnBrackets() {
        #expect(MathNotation.segments(of: "e^(iπ)").map(\.text) == ["e", "iπ"])
        #expect(MathNotation.segments(of: "f^(g(x))").map(\.text) == ["f", "g(x)"])
        let singleSup = MathNotation.segments(of: "QK^T + \\sum_{j=1}^K + ^∞")
        #expect(singleSup.contains(where: { $0.text == "T" && $0.script == .sup }))
        #expect(singleSup.contains(where: { $0.text == "K" && $0.script == .sup }))
        #expect(singleSup.contains(where: { $0.text == "∞" && $0.script == .sup }))
    }

    @Test func aVoiceDoesNotReadTheMarkersOutLoud() {
        let spoken = MathNotation.spoken("e^{i\\pi}")
        #expect(!spoken.contains("₍") && !spoken.contains("^("))
        // The body of a fallback script is still said, just without its brackets.
        #expect(MathNotation.spoken("\\nabla_\\theta").contains("theta"))
    }


    // MARK: - The type runs keep the order of the line

    @Test func typeRunsNeverReorderTheLine() {
        // Two accumulators that only flush at the end draw all the letters, then all the
        // punctuation: "E = mc²" came out "Emc = ²" in the transcript.
        for sample in ["E = mc²", "(ℳ₍grass₎, g₍μν₎)", "The energy is E = mc² and n log n is fine.",
                       "(eiπ, i, π, 1, 0)", "∇₍θ₎ℒ and ‖x‖₂"] {
            #expect(MathNotation.typeRuns(sample).map(\.text).joined() == sample)
        }
        #expect(MathNotation.typeRuns("E = mc²").map(\.text) == ["E", " = ", "mc", "²"])
        #expect(MathNotation.typeRuns("E = mc²").map(\.italic) == [true, false, true, false])
    }

    // MARK: - Cost

    /// A streaming reply re-parses its whole text on every token; a paragraph of math must
    /// cost close to one pass, not one pass per span (the old path rebuilt the whole
    /// attributed string for every span, so 400 spans took ~230 ms on the main thread).
    @Test func manySpansParseInOnePass() {
        let para = String(repeating: "Text $x_i^2$ more words here and $\\alpha+\\beta$ then ", count: 500)
        let start = Date()
        let attr = MarkdownParser.inline(para)
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(MathNotation.findInlineMath(in: para).count == 1000)
        #expect(String(attr.characters).contains("α"))
        #expect(ms < 1_500, "1000 spans took \(Int(ms)) ms")

        let again = Date()
        _ = MarkdownParser.inline(para)
        #expect(Date().timeIntervalSince(again) * 1000 < 1_000)
    }

    // MARK: - Loop Resilience & Fraction Variants

    @Test func loopResilienceWithPrefixInterferenceAndStreamingTokens() {
        // 1. Accents: \barrier should not abort \bar{x}
        let accentInput = "\\barrier + \\bar{x} + \\bar{y}"
        let accentOutput = MathNotation.format(accentInput)
        #expect(accentOutput.contains("x̄") && accentOutput.contains("ȳ"))

        // 2. Fractions: streaming/malformed \frac should not drop later \frac
        let fracInput = "\\frac{1} + \\frac{a}{b}"
        let fracOutput = MathNotation.format(fracInput)
        #expect(fracOutput.contains("a/b"))

        // 3. Fraction variants: \dfrac and \tfrac
        let dfracInput = "\\dfrac{1}{2} + \\tfrac{3}{4}"
        let dfracOutput = MathNotation.format(dfracInput)
        #expect(dfracOutput.contains("1/2") && dfracOutput.contains("3/4"))

        // 4. Stacking: malformed \overset should not drop later \overset
        let stackInput = "\\overset{?}{=} and \\overset{!}{=}"
        let stackOutput = MathNotation.format(stackInput)
        #expect(!stackOutput.contains("\\overset"))

        // 5. Incomplete fraction should not eat + as denominator
        let incompleteFrac = "\\frac{1} + \\frac{a}{b}"
        let incompleteOut = MathNotation.format(incompleteFrac)
        #expect(!incompleteOut.contains("1/+"))
        #expect(incompleteOut.contains("a/b"))
    }
}
