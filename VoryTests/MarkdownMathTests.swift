import Foundation
import Testing
@testable import VoryCore
@testable import Vory

@Suite struct MarkdownMathTests {

    @Test func inlineMathBasicFormula() {
        let input = "The energy is $E = mc^2$ according to Einstein."
        let attr = MarkdownParser.inline(input)
        let rendered = String(attr.characters)
        #expect(rendered == "The energy is E = mc² according to Einstein.")

        // Verify that math attribute is attached to the formula run
        var foundMathRun = false
        for run in attr.runs {
            if let mathVal = run.math {
                #expect(mathVal == "E = mc^2")
                foundMathRun = true
            }
        }
        #expect(foundMathRun)
    }

    @Test func inlineMathGreekAndOperators() {
        let input = "Assume $\\alpha + \\beta \\le \\gamma \\times \\delta$ holds."
        let attr = MarkdownParser.inline(input)
        let rendered = String(attr.characters)
        #expect(rendered == "Assume α + β ≤ γ × δ holds.")
    }

    @Test func inlineMathSubscriptsAndSuperscripts() {
        let input = "Define $x_1 + x_2 = y^2$ and $a_i \\in \\mathbb{R}$."
        let attr = MarkdownParser.inline(input)
        let rendered = String(attr.characters)
        #expect(rendered.contains("x₁ + x₂ = y²"))
        #expect(rendered.contains("aᵢ ∈ ℝ"))
    }

    @Test func inlineMathProtectsUnderscoresAndAsterisksFromMarkdownCorruption() {
        // In standard markdown, underscores normally become italics and asterisks become bold/italics.
        // Math protection ensures formulas like $x_i * y_j$ retain their exact math structure.
        let input = "Let $x_i * y_j$ be the product."
        let attr = MarkdownParser.inline(input)
        let rendered = String(attr.characters)
        #expect(rendered == "Let xᵢ * yⱼ be the product.")

        // Verify it was not mangled by markdown emphasis
        for run in attr.runs {
            if let mathVal = run.math {
                #expect(mathVal == "x_i * y_j")
            }
        }
    }

    @Test func inlineMathParentheticalNotation() {
        let input = "Check \\(\\sigma = \\sqrt{N}\\) here."
        let attr = MarkdownParser.inline(input)
        let rendered = String(attr.characters)
        #expect(rendered == "Check σ = √(N) here.")
    }

    @Test func currencyAndEscapedDollarsAreNotMath() {
        // Escaped dollar
        let escaped = "A laptop costs \\$1200 today."
        let attrEscaped = MarkdownParser.inline(escaped)
        #expect(String(attrEscaped.characters).contains("$1200"))
        #expect(!attrEscaped.runs.contains(where: { $0.math != nil }))

        // Price comparison in a normal sentence
        let prices = "Costs $5 and then $10 later."
        let attrPrices = MarkdownParser.inline(prices)
        #expect(String(attrPrices.characters) == "Costs $5 and then $10 later.")
        #expect(!attrPrices.runs.contains(where: { $0.math != nil }))
    }

    @Test func singleLineDisplayMathBlock() {
        let text = "$$E = mc^2$$"
        let blocks = MarkdownParser.blocks(from: text)
        #expect(blocks.count == 1)
        if case .math(let eq, let closed) = blocks.first {
            #expect(eq == "E = mc^2")
            #expect(closed == true)
        } else {
            Issue.record("Expected .math block, got \(blocks)")
        }
    }

    @Test func bracketDisplayMathBlock() {
        let text = "\\[\\int_0^1 f(x) dx\\]"
        let blocks = MarkdownParser.blocks(from: text)
        #expect(blocks.count == 1)
        if case .math(let eq, let closed) = blocks.first {
            #expect(eq == "\\int_0^1 f(x) dx")
            #expect(closed == true)
        } else {
            Issue.record("Expected .math block, got \(blocks)")
        }
    }

    @Test func multiLineDisplayMathBlock() {
        let text = """
        Intro paragraph

        $$
        f(x) = x^2 + 1
        $$

        Outro paragraph
        """
        let blocks = MarkdownParser.blocks(from: text)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .paragraph("Intro paragraph"))
        #expect(blocks[1] == .math(equation: "f(x) = x^2 + 1", closed: true))
        #expect(blocks[2] == .paragraph("Outro paragraph"))
    }

    @Test func unclosedDisplayMathWhileStreaming() {
        let text = "$$\nf(x) = \\sum_{i=1}^n x_i"
        let blocks = MarkdownParser.blocks(from: text)
        #expect(blocks.count == 1)
        if case .math(let eq, let closed) = blocks.first {
            #expect(eq == "f(x) = \\sum_{i=1}^n x_i")
            #expect(closed == false)
        } else {
            Issue.record("Expected open .math block, got \(blocks)")
        }
    }

    @Test func markdownPlainTextFormat() {
        let text = "$$\\alpha + \\beta = \\gamma$$"
        let plain = MarkdownPlainText.from(text)
        #expect(plain == "α + β = γ")
    }

    @Test func spokenTextCleansMathForSpeech() {
        let line = "We have $\\alpha \\le \\beta$."
        let spoken = SpokenText.inlineForSpeech(line)
        #expect(spoken.contains("alpha less than or equal to beta"))
        #expect(!spoken.contains("$"))
        #expect(!spoken.contains("\\"))
    }

    // MARK: - Strict Real-World Formula Tests from Screenshots

    @Test func gaussianIntegralStrict() {
        let input = "I = \\int_{-\\infty}^\\infty e^{-x^2} dx"
        let formatted = MathNotation.format(input)
        #expect(formatted.contains("∫"))
        #expect(formatted.contains("∞"))
        #expect(formatted.contains("e^(-x²)"))
        #expect(!formatted.contains("{"))
        #expect(!formatted.contains("}"))
        #expect(!formatted.contains("\\int"))
        #expect(!formatted.contains("\\infty"))
    }

    @Test func delimiterScalingStrict() {
        let input = "I^2 = \\left( \\int_{-\\infty}^\\infty e^{-x^2} dx \\right) \\left( \\int_{-\\infty}^\\infty e^{-y^2} dy \\right)"
        let formatted = MathNotation.format(input)
        // Must never corrupt \left into ≤ft
        #expect(!formatted.contains("≤ft"))
        #expect(!formatted.contains("\\left"))
        #expect(!formatted.contains("\\right"))
        #expect(formatted.contains("I² = ("))
        #expect(formatted.contains("e^(-x²)"))
        #expect(formatted.contains("e^(-y²)"))
        #expect(!formatted.contains("{"))
        #expect(!formatted.contains("}"))
    }

    @Test func normalDistributionPdfStrict() {
        let input = "f(x \\mid \\mu, \\sigma^2) = \\frac{1}{\\sigma \\sqrt{2\\pi}} \\exp\\left( - \\frac{(x - \\mu)^2}{2\\sigma^2} \\right)"
        let formatted = MathNotation.format(input)
        #expect(formatted.contains("|"))
        #expect(!formatted.contains("\\mid"))
        #expect(formatted.contains("exp("))
        #expect(!formatted.contains("\\exp"))
        #expect(!formatted.contains("≤ft"))
        #expect(!formatted.contains("\\left"))
        #expect(!formatted.contains("\\right"))
        #expect(formatted.contains("μ"))
        #expect(formatted.contains("σ²"))
        #expect(formatted.contains("√(2π)"))
        #expect(!formatted.contains("\\frac"))
        #expect(!formatted.contains("{"))
        #expect(!formatted.contains("}"))
    }

    @Test func eulerIdentityStrict() {
        let input = "e^{i\\pi} + 1 = 0"
        let formatted = MathNotation.format(input)
        #expect(formatted == "e^(iπ) + 1 = 0")
        #expect(!formatted.contains("{"))
        #expect(!formatted.contains("}"))
    }

    @Test func inlineCalligraphicStrict() {
        let withBraces = "distribution $\\mathcal{N}(\\mu, \\sigma^2)$"
        let attrWithBraces = MarkdownParser.inline(withBraces)
        let str1 = String(attrWithBraces.characters)
        #expect(str1.contains("𝒩(μ, σ²)"))
        #expect(!str1.contains("\\mathcal"))

        let withoutBraces = "distribution $\\mathcalN(\\mu, \\sigma^2)$"
        let attrWithoutBraces = MarkdownParser.inline(withoutBraces)
        let str2 = String(attrWithoutBraces.characters)
        #expect(str2.contains("𝒩(μ, σ²)"))
        #expect(!str2.contains("\\mathcal"))
    }

    @Test func inlineDifferentialStrict() {
        let input = "element $dx\\ dy \\to r\\ dr\\ d\\theta$"
        let attr = MarkdownParser.inline(input)
        let str = String(attr.characters)
        #expect(str.contains("dx dy → r dr dθ"))
        #expect(!str.contains("\\to"))
        #expect(!str.contains("\\theta"))
    }

    @Test func polarCoordinatesStrict() {
        let input = "coordinates $(r, \\theta)$"
        let attr = MarkdownParser.inline(input)
        let str = String(attr.characters)
        #expect(str.contains("(r, θ)"))
    }

    @Test func inlineNakedLaTeXCommands() {
        // Real-world cases from chat where the model generates LaTeX commands without enclosing in $...$
        let logo = "Here is crisp \\LaTeX so you can see"
        let attrLogo = MarkdownParser.inline(logo)
        #expect(String(attrLogo.characters).contains("crisp LaTeX so you can see"))
        #expect(!String(attrLogo.characters).contains("\\LaTeX"))

        let polar = "switch to polar coordinates (r, \\theta) like an absolute gigachad"
        let attrPolar = MarkdownParser.inline(polar)
        #expect(String(attrPolar.characters).contains("polar coordinates (r, θ)"))
        #expect(!String(attrPolar.characters).contains("\\theta"))

        let diff = "differential area element dx dy \\rightarrow r dr d\\theta:"
        let attrDiff = MarkdownParser.inline(diff)
        #expect(String(attrDiff.characters).contains("dx dy → r dr dθ:"))
        #expect(!String(attrDiff.characters).contains("\\rightarrow"))
        #expect(!String(attrDiff.characters).contains("\\theta"))

        let dist1 = "standard normal distribution \\mathcalN(\\mu, \\sigma^2):"
        let attrDist1 = MarkdownParser.inline(dist1)
        #expect(String(attrDist1.characters).contains("𝒩(μ, σ²):"))
        #expect(!String(attrDist1.characters).contains("\\mathcal"))

        let dist2 = "standard normal distribution \\mathcal{N}(\\mu, \\sigma^2):"
        let attrDist2 = MarkdownParser.inline(dist2)
        #expect(String(attrDist2.characters).contains("𝒩(μ, σ²):"))
        #expect(!String(attrDist2.characters).contains("\\mathcal"))

        let constants = "fundamental constants (e, i, \\pi, 1, 0):"
        let attrConst = MarkdownParser.inline(constants)
        #expect(String(attrConst.characters).contains("constants (e, i, π, 1, 0):"))
        #expect(!String(attrConst.characters).contains("\\pi"))
    }

    @Test func inlineNakedLaTeXPreservesCodeAndProse() {
        // Inline code spans must not be altered
        let code = "Use `\\n` and `\\alpha` here"
        let attrCode = MarkdownParser.inline(code)
        #expect(String(attrCode.characters).contains("\\n"))
        #expect(String(attrCode.characters).contains("\\alpha"))

        // Snake_case variable names must not have letters converted to subscripts
        let snake = "Here is a_variable_name in code."
        let attrSnake = MarkdownParser.inline(snake)
        #expect(String(attrSnake.characters).contains("a_variable_name"))

        // Windows-style file paths must not be corrupted
        let path = "Path C:\\Users\\andrew\\file.txt"
        let attrPath = MarkdownParser.inline(path)
        #expect(String(attrPath.characters).contains("C:\\Users\\andrew\\file.txt"))
    }

    @Test func polarIntegralWithBracketsStrict() {
        let input = "2\\pi \\left[ -1/2 e^{-r^2} \\right]_0^{\\infty} = 2\\pi \\left( 0 - \\left( -1/2 \\right) \\right) = \\pi"
        let formatted = MathNotation.format(input)
        #expect(!formatted.contains("≤ft"))
        #expect(!formatted.contains("\\left"))
        #expect(!formatted.contains("\\right"))
        #expect(formatted.contains("2π [ -1/2 e^(-r²) ]"))
        #expect(formatted.contains("= π"))
        #expect(!formatted.contains("{"))
        #expect(!formatted.contains("}"))
    }

    // MARK: - KaTeX Engine & 2D Math Card Tests

    @Test func kaTeXEngineRendersValid2DMarkup() async {
        let equations = [
            "I = \\int_{-\\infty}^{\\infty} e^{-x^2} dx",
            "I = \\sqrt{\\pi}",
            "f(x \\mid \\mu, \\sigma^2) = \\frac{1}{\\sigma \\sqrt{2\\pi}} \\exp\\left( -\\frac{(x - \\mu)^2}{2\\sigma^2} \\right)",
            "e^{i\\pi} + 1 = 0"
        ]

        for eq in equations {
            let html = await KaTeXEngine.shared.render(latex: eq)
            #expect(!html.isEmpty)
            #expect(html != "undefined")
            #expect(!html.contains("undefined"))
            #expect(html.contains("katex-display") || html.contains("katex"))
            #expect(html.contains("<span class=\"katex\">") || html.contains("<span class=\"katex-display\">"))
        }
    }

    @Test func kaTeXCacheStoresAndRetrievesMarkupAndSize() {
        let testEq = "E = mc^2"
        let markup = "<span class=\"katex\">E = mc^2</span>"
        let size = CGSize(width: 150, height: 44)

        KaTeXCache.setMarkup(markup, for: testEq)
        KaTeXCache.setSize(size, for: testEq)

        #expect(KaTeXCache.markup(for: testEq) == markup)
        #expect(KaTeXCache.size(for: testEq) == size)
    }

    @Test func mathCardDocumentGeneration() {
        let markup = "<span class=\"katex-display\">I = \\sqrt{\\pi}</span>"
        let darkDoc = MathCard.document(mathMarkup: markup, dark: true)
        let lightDoc = MathCard.document(mathMarkup: markup, dark: false)

        #expect(darkDoc.contains("color-scheme: dark"))
        #expect(darkDoc.contains(markup))
        #expect(!darkDoc.contains("undefined"))

        #expect(lightDoc.contains("color-scheme: light"))
        #expect(lightDoc.contains(markup))
        #expect(!lightDoc.contains("undefined"))
    }

    @Test func kaTeXAssetsEmbedsWoff2FontsDirectly() {
        let css = KaTeXAssets.cssString
        #expect(!css.isEmpty)
        // Must contain embedded base64 WOFF2 fonts so WebKit never falls back to normal system font
        #expect(css.contains("data:font/woff2;base64,"))
        #expect(css.contains("KaTeX_Main"))
        #expect(css.contains("KaTeX_Math"))
        #expect(css.contains("KaTeX_Size1"))
        #expect(css.contains("KaTeX_AMS"))
        // Must not reference missing relative url(fonts/...) paths
        #expect(!css.contains("url(fonts/"))
    }

    @Test func laTeXMathEnvironmentsAsBlocks() {
        let text = """
        \\begin{align}
        a &= b + c \\\\
        d &= e + f
        \\end{align}
        """
        let blocks = MarkdownParser.blocks(from: text)
        #expect(blocks.count == 1)
        if case .math(let eq, let closed) = blocks.first {
            #expect(eq.contains("\\begin{align}"))
            #expect(eq.contains("\\end{align}"))
            #expect(closed == true)
        } else {
            Issue.record("Expected .math block for LaTeX environment, got \(blocks)")
        }

        let matrix = "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}"
        let matrixBlocks = MarkdownParser.blocks(from: matrix)
        #expect(matrixBlocks.count == 1)
        if case .math(let eq, let closed) = matrixBlocks.first {
            #expect(eq == matrix)
            #expect(closed == true)
        } else {
            Issue.record("Expected .math block for single-line pmatrix, got \(matrixBlocks)")
        }
    }

    @Test func multipleInlineMathSpansWithUnderscoresNotManglingTokens() {
        let input = "Values $x_1$ and $y_2$ and $z_3$ hold."
        let attr = MarkdownParser.inline(input)
        let rendered = String(attr.characters)
        #expect(rendered == "Values x₁ and y₂ and z₃ hold.")
        let mathRuns = attr.runs.compactMap(\.math)
        #expect(mathRuns.count == 3)
        #expect(mathRuns == ["x_1", "y_2", "z_3"])
    }

    @Test func ghostSubscriptNotationDoesNotShowRaw() {
        let cases = [
            ("The mass is M_ (ghost) in gauge theory", "M₍ghost₎"),
            ("The mass is M_(ghost) in gauge theory", "M₍ghost₎"),
            ("The mass is M_{ghost} in gauge theory", "M₍ghost₎"),
            ("The mass is M_{\\text{ghost}} in gauge theory", "M₍ghost₎"),
            ("The mass is M_\\text{ghost} in gauge theory", "M₍ghost₎"),
            ("The mass is M_ {ghost} in gauge theory", "M₍ghost₎")
        ]

        for (input, expectedSub) in cases {
            let attr = MarkdownParser.inline(input)
            let rendered = String(attr.characters)
            #expect(rendered.contains(expectedSub), "Failed for input: \(input), got: \(rendered)")
            #expect(!rendered.contains("M_ (ghost)"))
            #expect(!rendered.contains("M_(ghost)"))
            #expect(!rendered.contains("M_{ghost}"))
            #expect(!rendered.contains("\\text"))
        }

        // Also verify inside math delimiters $M_{\text{ghost}}$
        let delimited = "Consider $M_{\\text{ghost}}$ here."
        let attrDelimited = MarkdownParser.inline(delimited)
        let renderedDelimited = String(attrDelimited.characters)
        #expect(renderedDelimited.contains("M₍ghost₎"))
        #expect(!renderedDelimited.contains("M_"))

        // Verify normal snake_case identifiers are preserved and not mangled
        let codeLike = "Use the snake_case_identifier and another_variable_name here."
        let attrCode = MarkdownParser.inline(codeLike)
        let renderedCode = String(attrCode.characters)
        #expect(renderedCode.contains("snake_case_identifier"))
        #expect(renderedCode.contains("another_variable_name"))
    }

    // MARK: - Tables with Math Pipes & Display Math Line Delimiters

    @Test func tableCellsWithMathPipes() {
        let markdown = """
        | Condition | Value |
        |---|---|
        | $P(A|B)$ | $f(x) = |x|$ |
        """
        let blocks = MarkdownParser.blocks(from: markdown)
        guard case .table(let table) = blocks.first else {
            Issue.record("Expected table block")
            return
        }
        #expect(table.header.count == 2)
        #expect(table.rows.count == 1)
        #expect(table.rows[0].count == 2)
        #expect(table.rows[0][0].contains("P(A|B)"))
        #expect(table.rows[0][1].contains("|x|"))
    }

    @Test func tableCellsWithVariedLaTeXRepresentations() {
        let markdown = """
        | Metric | Delimited $ | Parentheses \\( | Display \\[ | Display $$ | Naked |
        |---|---|---|---|---|---|
        | Bayes | $P(A|B)$ | \\(P(A|B)\\) | \\[x_1 + x_2\\] | $$y^2 + z^2$$ | \\alpha + \\beta = \\gamma |
        | Precision | $P = \\frac{TP}{TP + FP}$ | \\(R = \\frac{TP}{TP + FN}\\) | \\[\\sqrt{x}\\] | $$\\int_0^1 f(x)dx$$ | \\frac{a}{b} |
        | Set | $x \\in \\{1, 2\\}$ | \\(x \\in \\{1, 2\\}\\) | \\[x \\in \\{1, 2\\}\\] | $$x \\in \\{1, 2\\}$$ | x \\in \\{1, 2\\} |
        """
        let blocks = MarkdownParser.blocks(from: markdown)
        guard case .table(let table) = blocks.first else {
            Issue.record("Expected table block")
            return
        }
        #expect(table.header.count == 6)
        #expect(table.rows.count == 3)

        for row in table.rows {
            #expect(row.count == 6)
            for cell in row {
                let formatted = MarkdownParser.inline(cell)
                let str = String(formatted.characters)
                // No raw unparsed delimiters or naked command syntax should remain
                #expect(!str.contains("\\("), "Cell should not contain unparsed \\(: \(str)")
                #expect(!str.contains("\\)"), "Cell should not contain unparsed \\): \(str)")
                #expect(!str.contains("\\["), "Cell should not contain unparsed \\[: \(str)")
                #expect(!str.contains("\\]"), "Cell should not contain unparsed \\]: \(str)")
                #expect(!str.contains("$$"), "Cell should not contain unparsed $$: \(str)")
                #expect(!str.contains("\\alpha"), "Cell should not contain unparsed \\alpha: \(str)")
                #expect(!str.contains("\\beta"), "Cell should not contain unparsed \\beta: \(str)")
                #expect(!str.contains("\\gamma"), "Cell should not contain unparsed \\gamma: \(str)")
                #expect(!str.contains("\\frac"), "Cell should not contain unparsed \\frac: \(str)")
            }
        }

        // Specifically test the escaped braces in set notation
        let setDelimited = MarkdownParser.inline("$x \\in \\{1, 2\\}$")
        #expect(String(setDelimited.characters).contains("{1, 2}"))

        let setNaked = MarkdownParser.inline("x \\in \\{1, 2\\}")
        #expect(String(setNaked.characters).contains("{1, 2}"))
    }

    @Test func singleLineDisplayMathWithTrailingProseDoesNotHijackParagraphs() {
        let markdown = """
        $$x = 1$$ where x is initial state
        This is regular prose that must not be swallowed.
        """
        let blocks = MarkdownParser.blocks(from: markdown)
        #expect(blocks.count >= 2)
        guard case .paragraph(let text) = blocks.last else {
            Issue.record("Expected last block to be paragraph, got \(String(describing: blocks.last))")
            return
        }
        #expect(text.contains("regular prose"))
    }

    @Test func kaTeXFallbackHTMLEscaping() {
        let malicious = "<script>alert('xss')</script>"
        let escaped = MathCard.escapeHtml(malicious)
        #expect(!escaped.contains("<script>"))
        #expect(escaped.contains("&lt;script&gt;"))
    }

    @Test func multilineDisplayMathTrailingProseClosesProperly() {
        let markdown = """
        $$
        \\int_0^1 x dx
        x = 1 $$ where x is real
        Next paragraph.
        """
        let blocks = MarkdownParser.blocks(from: markdown)
        #expect(blocks.count >= 2)
        guard case .math(let eq, let closed) = blocks.first else {
            Issue.record("Expected first block to be math")
            return
        }
        #expect(closed)
        #expect(!eq.contains("where x is real"))

        guard case .paragraph(let text) = blocks.last else {
            Issue.record("Expected last block to be paragraph")
            return
        }
        #expect(text.contains("Next paragraph"))
    }

    @Test func tableWithCurrencyAndDisplayMath() {
        let markdown = """
        | Price | Condition |
        |---|---|
        | $5 | $P(A|B)$ |
        """
        let blocks = MarkdownParser.blocks(from: markdown)
        guard case .table(let table) = blocks.first else {
            Issue.record("Expected table")
            return
        }
        #expect(table.header.count == 2)
        #expect(table.rows.count == 1)
        #expect(table.rows[0].count == 2)
        #expect(table.rows[0][0].contains("$5"))
        #expect(table.rows[0][1].contains("P(A|B)"))
    }
}
