import Foundation

// MARK: - AttributedString Math Attribute

public enum MathInlineAttribute: AttributedStringKey {
    public typealias Value = String
    public static let name = "MathInline"
}

public extension AttributeScopes {
    struct VoryCoreAttributes: AttributeScope {
        public let math: MathInlineAttribute
    }
    var voryCore: VoryCoreAttributes.Type { VoryCoreAttributes.self }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.VoryCoreAttributes, T>) -> T {
        self[T.self]
    }
}

/// Fast, zero-dependency LaTeX math notation normalizer and renderer for Apple platforms.
/// Translates LaTeX math expressions into mathematical typography and symbols.
///
/// Two contexts, two sets of rules. `Context.math` is text known to be a formula, so leftover TeX
/// grouping braces may be dropped. `Context.prose` is a chat message that merely *contains* LaTeX
/// (a naked `\theta`, an `M_ (ghost)`): there the formatter is a guest and must never eat a brace
/// or an unknown command, because `{a, b}`, `\foobar{1}` and JSON are prose, not TeX.
public enum MathNotation: Sendable {

    /// Which rules apply: a formula, or LaTeX loose in prose.
    enum Context: Sendable {
        case math
        case prose
    }

    // MARK: - Greek Letters
    private static let greek: [(pattern: String, replacement: String)] = [
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"),
        ("epsilon", "ε"), ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"),
        ("theta", "θ"), ("vartheta", "ϑ"), ("iota", "ι"), ("kappa", "κ"), ("varkappa", "ϰ"),
        ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"),
        ("pi", "π"), ("varpi", "ϖ"), ("rho", "ρ"), ("varrho", "ϱ"),
        ("sigma", "σ"), ("varsigma", "ς"), ("tau", "τ"), ("upsilon", "υ"),
        ("phi", "φ"), ("varphi", "ϕ"), ("chi", "χ"), ("psi", "ψ"),
        ("omega", "ω"), ("digamma", "ϝ"),
        ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"),
        ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"), ("Upsilon", "Υ"),
        ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω")
    ]

    // MARK: - Mathematical Calligraphic Script
    private static let mathcal: [Character: Character] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ",
        "G": "𝒢", "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ",
        "M": "ℳ", "N": "𝒩", "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ",
        "S": "𝒮", "T": "𝒯", "U": "𝒰", "V": "𝒱", "W": "𝒲", "X": "𝒳",
        "Y": "𝒴", "Z": "𝒵",
        "a": "𝒶", "b": "𝒷", "c": "𝒸", "d": "𝒹", "e": "ℯ", "f": "𝒻",
        "g": "ℊ", "h": "𝒽", "i": "𝒾", "j": "𝒿", "k": "𝓀", "l": "𝓁",
        "m": "𝓂", "n": "𝓃", "o": "ℴ", "p": "𝓅", "q": "𝓆", "r": "𝓇",
        "s": "𝓈", "t": "𝓉", "u": "𝓊", "v": "𝓋", "w": "𝓌", "x": "𝓍",
        "y": "𝓎", "z": "𝓏"
    ]

    /// Double-struck capitals and lower case, and the digits (`\mathbb{1}` is an indicator).
    private static let blackboard: [Character: Character] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽",
        "G": "𝔾", "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃",
        "M": "𝕄", "N": "ℕ", "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ",
        "S": "𝕊", "T": "𝕋", "U": "𝕌", "V": "𝕍", "W": "𝕎", "X": "𝕏",
        "Y": "𝕐", "Z": "ℤ",
        "a": "𝕒", "b": "𝕓", "c": "𝕔", "d": "𝕕", "e": "𝕖", "f": "𝕗",
        "g": "𝕘", "h": "𝕙", "i": "𝕚", "j": "𝕛", "k": "𝕜", "l": "𝕝",
        "m": "𝕞", "n": "𝕟", "o": "𝕠", "p": "𝕡", "q": "𝕢", "r": "𝕣",
        "s": "𝕤", "t": "𝕥", "u": "𝕦", "v": "𝕧", "w": "𝕨", "x": "𝕩",
        "y": "𝕪", "z": "𝕫",
        "0": "𝟘", "1": "𝟙", "2": "𝟚", "3": "𝟛", "4": "𝟜",
        "5": "𝟝", "6": "𝟞", "7": "𝟟", "8": "𝟠", "9": "𝟡"
    ]

    // MARK: - Symbols & Operators with Boundary Safety
    private static let symbols: [(pattern: String, replacement: String)] = [
        ("times", "×"), ("cdot", "·"), ("cdotp", "·"), ("div", "÷"), ("pm", "±"), ("mp", "∓"),
        ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"),
        ("neq", "≠"), ("ne", "≠"), ("approx", "≈"), ("sim", "∼"), ("simeq", "≃"),
        ("equiv", "≡"), ("cong", "≅"), ("asymp", "≍"), ("doteq", "≐"),
        ("ll", "≪"), ("gg", "≫"), ("prec", "≺"), ("succ", "≻"), ("preceq", "⪯"), ("succeq", "⪰"),
        ("infty", "∞"), ("propto", "∝"),
        ("forall", "∀"), ("exists", "∃"), ("nexists", "∄"),
        ("notin", "∉"), ("in", "∈"), ("ni", "∋"),
        ("subset", "⊂"), ("subseteq", "⊆"), ("subsetneq", "⊊"),
        ("supset", "⊃"), ("supseteq", "⊇"), ("supsetneq", "⊋"),
        ("sqsubset", "⊏"), ("sqsubseteq", "⊑"),
        ("cup", "∪"), ("cap", "∩"), ("setminus", "∖"), ("smallsetminus", "∖"),
        ("emptyset", "∅"), ("varnothing", "∅"),
        ("rightarrow", "→"), ("to", "→"), ("gets", "←"), ("leftarrow", "←"),
        ("Rightarrow", "⇒"), ("Leftarrow", "⇐"), ("Leftrightarrow", "⇔"),
        ("longrightarrow", "⟶"), ("Longrightarrow", "⟹"),
        ("longleftarrow", "⟵"), ("Longleftarrow", "⟸"),
        ("longleftrightarrow", "⟷"), ("Longleftrightarrow", "⟺"),
        ("hookrightarrow", "↪"), ("hookleftarrow", "↩"),
        ("rightleftharpoons", "⇌"), ("nearrow", "↗"), ("searrow", "↘"),
        ("swarrow", "↙"), ("nwarrow", "↖"),
        ("uparrow", "↑"), ("downarrow", "↓"), ("Uparrow", "⇑"), ("Downarrow", "⇓"),
        ("iff", "⟺"), ("implies", "⟹"), ("mapsto", "↦"),
        ("partial", "∂"), ("nabla", "∇"), ("hbar", "ℏ"), ("hslash", "ℏ"),
        ("iint", "∬"), ("iiint", "∭"), ("oint", "∮"), ("int", "∫"),
        ("sum", "∑"), ("prod", "∏"), ("coprod", "∐"),
        ("surd", "√"), ("angle", "∠"), ("measuredangle", "∡"),
        ("perp", "⊥"), ("parallel", "∥"), ("nparallel", "∦"),
        ("vdash", "⊢"), ("dashv", "⊣"), ("models", "⊨"), ("top", "⊤"), ("bot", "⊥"),
        ("cdots", "⋯"), ("ldots", "…"), ("dots", "…"), ("dotsb", "⋯"), ("dotsc", "…"),
        ("dotsm", "⋯"), ("dotsi", "⋯"), ("ddots", "⋱"), ("vdots", "⋮"),
        ("prime", "′"), ("ell", "ℓ"), ("imath", "ı"), ("jmath", "ȷ"),
        ("triangle", "△"), ("square", "□"), ("Box", "□"),
        ("diamond", "⋄"), ("blacksquare", "■"),
        ("oplus", "⊕"), ("ominus", "⊖"), ("otimes", "⊗"), ("oslash", "⊘"), ("odot", "⊙"),
        ("ast", "∗"), ("star", "⋆"), ("circ", "∘"), ("bullet", "•"),
        ("langle", "⟨"), ("rangle", "⟩"), ("lvert", "|"), ("rvert", "|"),
        ("lVert", "‖"), ("rVert", "‖"), ("vert", "|"), ("Vert", "‖"),
        ("lceil", "⌈"), ("rceil", "⌉"), ("lfloor", "⌊"), ("rfloor", "⌋"),
        ("ulcorner", "⌜"), ("urcorner", "⌝"), ("llcorner", "⌞"), ("lrcorner", "⌟"),
        ("lbrace", "{"), ("rbrace", "}"),
        ("therefore", "∴"), ("because", "∵"), ("aleph", "ℵ"), ("beth", "ℶ"),
        ("Re", "ℜ"), ("Im", "ℑ"), ("wp", "℘"),
        ("neg", "¬"), ("lnot", "¬"), ("land", "∧"), ("wedge", "∧"), ("lor", "∨"), ("vee", "∨"),
        ("colon", ":"), ("mid", "|"), ("nmid", "∤"), ("backslash", "∖"),
        ("sharp", "♯"), ("flat", "♭"), ("natural", "♮"), ("degree", "°"),
        ("sin", "sin"), ("cos", "cos"), ("tan", "tan"), ("sec", "sec"), ("csc", "csc"), ("cot", "cot"),
        ("arcsin", "arcsin"), ("arccos", "arccos"), ("arctan", "arctan"),
        ("sinh", "sinh"), ("cosh", "cosh"), ("tanh", "tanh"),
        ("exp", "exp"), ("ln", "ln"), ("log", "log"), ("lg", "lg"),
        ("det", "det"), ("dim", "dim"), ("gcd", "gcd"), ("hom", "hom"),
        ("inf", "inf"), ("sup", "sup"), ("ker", "ker"),
        ("arg", "arg"), ("deg", "deg"), ("liminf", "lim inf"), ("limsup", "lim sup"),
        ("lim", "lim"), ("max", "max"), ("min", "min"), ("mod", "mod"), ("bmod", "mod"), ("pmod", "mod")
    ]

    // MARK: - Pre-compiled Command Lookup Dictionary
    private static let commandLookup: [String: String] = {
        var dict: [String: String] = [:]
        for (cmd, repl) in greek { dict[cmd] = repl }
        for (cmd, repl) in symbols { dict[cmd] = repl }
        return dict
    }()

    /// Accents and rules: `\vec{v}` → v⃗, `\overline{AB}` → A̅B̅. The mark is applied to every
    /// character of the argument, as TeX draws it over the whole group.
    private static let accents: [(cmd: String, mark: Unicode.Scalar)] = [
        ("overrightarrow", "\u{20D7}"), ("overleftarrow", "\u{20D6}"),
        ("widehat", "\u{0302}"), ("widetilde", "\u{0303}"),
        ("overline", "\u{0305}"), ("underline", "\u{0332}"),
        ("vec", "\u{20D7}"), ("hat", "\u{0302}"), ("bar", "\u{0304}"), ("tilde", "\u{0303}"),
        ("ddot", "\u{0308}"), ("dot", "\u{0307}"), ("check", "\u{030C}"), ("breve", "\u{0306}"),
        ("acute", "\u{0301}"), ("grave", "\u{0300}")
    ]

    /// Commands that only carry type: their argument is the text to keep.
    private static let textCommands: [String] = [
        "\\operatorname*", "\\operatorname", "\\textnormal", "\\textsc", "\\textrm",
        "\\textbf", "\\textit", "\\texttt", "\\textsf", "\\textup", "\\textsl",
        "\\text", "\\emph", "\\mbox", "\\hbox",
        "\\boldsymbol", "\\mathnormal", "\\mathrm", "\\mathbf", "\\mathit", "\\mathsf", "\\mathtt"
    ].sorted { $0.count > $1.count }

    private static let subDigits: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
        "v": "ᵥ", "x": "ₓ",
        "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ"
    ]

    private static let superDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "t": "ᵗ"
    ]

    // MARK: - Public Entry Points

    /// Fast heuristic to check if text might contain LaTeX math expressions, commands, or script notation.
    public static func mayContainMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\") ||
        text.contains("_{") || text.contains("^{") ||
        text.contains("_(") || text.contains("^(") ||
        text.contains("_ (") || text.contains("_ {") ||
        text.contains("^ {") || text.contains("^ (")
    }

    /// Formats naked LaTeX math commands outside code spans (e.g. \LaTeX, \theta, \rightarrow, \mathcalN, M_ (ghost))
    /// into clean Unicode mathematical symbols. Prose rules: known commands only, and a brace that
    /// belongs to no command is left alone — `{a, b}` is a set in the sentence, not TeX grouping.
    public static func formatNakedCommands(in text: String) -> String {
        guard mayContainMath(text) else { return text }
        guard text.contains("`") else { return formatted(text, context: .prose) }

        // Code spans are read by fence length, not by parity: a ``double`` span is one span, and
        // its contents are code even when they hold a formula.
        var out = ""
        var i = text.startIndex
        var segmentStart = text.startIndex
        while i < text.endIndex {
            guard text[i] == "`" else {
                i = text.index(after: i)
                continue
            }
            var run = 1
            var j = text.index(after: i)
            while j < text.endIndex, text[j] == "`" { run += 1; j = text.index(after: j) }
            let fence = String(repeating: "`", count: run)
            guard let close = text.range(of: fence, range: j..<text.endIndex) else {
                i = j // an unterminated run is prose after all
                continue
            }
            out += proseFormatted(String(text[segmentStart..<i]))
            out += text[i..<close.upperBound]
            i = close.upperBound
            segmentStart = i
        }
        out += proseFormatted(String(text[segmentStart...]))
        return out
    }

    private static func proseFormatted(_ text: String) -> String {
        mayContainMath(text) ? formatted(text, context: .prose) : text
    }

    /// Converts a raw LaTeX formula string into clean, readable typography with Unicode math symbols.
    public static func format(_ latex: String) -> String {
        formatted(latex, context: .math)
    }

    /// Converts a LaTeX formula into clean spoken English words for Voice / TTS.
    public static func spoken(_ latex: String) -> String {
        var s = format(latex)
        // Norms and absolute values before bare pipe replacements
        s = s.replacing(/‖([^‖]*)‖/) { match in " norm of \(match.1) " }
        s = s.replacing(/\|([^|]+)\|/) { match in " absolute value of \(match.1) " }

        // The fallback markers are for the eye only: "e^(iπ)" is "e to the power of iπ".
        s = s.replacing(/\^\(([^)]*)\)/) { match in " to the power of \(match.1) " }
        s = s.replacing(/\^([a-zA-Z0-9])/) { match in " to the power of \(match.1) " }
        s = s.replacingOccurrences(of: "₍", with: " ")
        s = s.replacingOccurrences(of: "₎", with: " ")
        let replacements: [(String, String)] = [
            ("α", "alpha"), ("β", "beta"), ("γ", "gamma"), ("δ", "delta"),
            ("ε", "epsilon"), ("ζ", "zeta"), ("η", "eta"), ("θ", "theta"),
            ("ι", "iota"), ("κ", "kappa"), ("λ", "lambda"), ("μ", "mu"),
            ("ν", "nu"), ("ξ", "xi"), ("π", "pi"), ("ρ", "rho"),
            ("σ", "sigma"), ("τ", "tau"), ("υ", "upsilon"), ("φ", "phi"),
            ("χ", "chi"), ("ψ", "psi"), ("ω", "omega"),
            ("Γ", "Gamma"), ("Δ", "Delta"), ("Θ", "Theta"), ("Λ", "Lambda"),
            ("Ξ", "Xi"), ("Π", "Pi"), ("Σ", "Sigma"), ("Υ", "Upsilon"),
            ("Φ", "Phi"), ("Ψ", "Psi"), ("Ω", "Omega"),
            ("𝒩", " normal distribution "), ("ℝ", " the reals "), ("ℕ", " the naturals "),
            ("ℤ", " the integers "), ("ℚ", " the rationals "), ("ℂ", " the complex numbers "),
            ("≤", " less than or equal to "), ("≥", " greater than or equal to "),
            ("≠", " not equal to "), ("≈", " approximately "), ("×", " times "),
            ("±", " plus or minus "), ("·", " times "), ("÷", " divided by "),
            ("→", " to "), ("⇒", " implies "), ("⟹", " implies "), ("⟺", " if and only if "),
            ("∈", " in "), ("∉", " not in "), ("⊂", " is a subset of "), ("⊆", " is a subset of or equal to "),
            ("∪", " union "), ("∩", " intersection "), ("∅", " the empty set "),
            ("∞", " infinity "), ("∑", " sum of "), ("∏", " product of "),
            ("∫", " integral of "), ("√", " the square root of "),
            ("∂", " the partial derivative of "), ("∇", " del "),
            ("²", " squared "), ("³", " cubed "), ("⁄", " over "), ("/", " over "),
            ("₀", " 0 "), ("₁", " 1 "), ("₂", " 2 "), ("₃", " 3 "), ("₄", " 4 "),
            ("₅", " 5 "), ("₆", " 6 "), ("₇", " 7 "), ("₈", " 8 "), ("₉", " 9 "),
            ("⁰", " to the power of 0 "), ("¹", " to the power of 1 "),
            ("⁴", " to the power of 4 "), ("⁵", " to the power of 5 "),
            ("⁶", " to the power of 6 "), ("⁷", " to the power of 7 "),
            ("⁸", " to the power of 8 "), ("⁹", " to the power of 9 "),
            ("ⁿ", " to the power of n "), ("ⁱ", " to the power of i "),
            ("ˣ", " to the power of x "), ("ʸ", " to the power of y "),
            ("ᵗ", " to the power of t "),
            ("|", " given ")
        ]
        for (k, v) in replacements {
            s = s.replacingOccurrences(of: k, with: v)
        }
        // Accent marks mean nothing to a voice.
        for mark in accents.map({ String($0.mark) }) {
            s = s.replacingOccurrences(of: mark, with: "")
        }
        return s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: - Display Runs

    /// Known operator function names that are set upright (roman), not italic, in standard LaTeX / KaTeX typography.
    private static let uprightOperators: Set<String> = [
        "sin", "cos", "tan", "sec", "csc", "cot", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "exp", "ln", "log", "lg",
        "det", "dim", "gcd", "hom", "ker", "arg", "deg", "mod", "bmod", "pmod",
        "lim", "liminf", "limsup", "max", "min", "inf", "sup",
        "softmax", "Softmax", "attn", "Attn", "relu", "ReLU"
    ]

    /// The type runs of a formula: a letter is set in italic, everything else upright, **in the
    /// order written**. Recognized operator function names ("sin", "ln", "softmax", "Attn") are set upright.
    public static func typeRuns(_ text: String) -> [(text: String, italic: Bool)] {
        var out: [(text: String, italic: Bool)] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isLetter {
                var j = text.index(after: i)
                while j < text.endIndex && text[j].isLetter { j = text.index(after: j) }
                let word = String(text[i..<j])
                if uprightOperators.contains(word) {
                    out.append((word, false))
                } else {
                    out.append((word, true))
                }
                i = j
            } else {
                var j = text.index(after: i)
                while j < text.endIndex && !text[j].isLetter { j = text.index(after: j) }
                out.append((String(text[i..<j]), false))
                i = j
            }
        }
        return out
    }

    // MARK: - Display Segments

    /// How a formatted run is drawn below or above the baseline.
    public enum Script: Sendable, Equatable {
        case baseline, sub, sup
    }

    /// The display segments of a formatted formula. A body with no Unicode script form is
    /// written `₍grass₎` for copy and for a voice; a text view draws it as a real subscript by
    /// taking the body out of those brackets, and `^(n × m)` or `^K` as a real superscript. Mappable
    /// scripts (`x₁`, `mc²`) are already the right glyphs and stay on the baseline.
    public static func segments(of formatted: String) -> [(text: String, script: Script)] {
        var out: [(text: String, script: Script)] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { out.append((plain, .baseline)); plain = "" }
        }
        var i = formatted.startIndex
        while i < formatted.endIndex {
            let ch = formatted[i]
            if ch == "₍", let close = formatted[formatted.index(after: i)...].firstIndex(of: "₎") {
                flush()
                out.append((String(formatted[formatted.index(after: i)..<close]), .sub))
                i = formatted.index(after: close)
                continue
            }
            if ch == "^" {
                let next = formatted.index(after: i)
                if next < formatted.endIndex, formatted[next] == "(" {
                    // The body may hold its own brackets: ^(f(x)) is one superscript.
                    var depth = 0
                    var j = next
                    var close: String.Index?
                    while j < formatted.endIndex {
                        if formatted[j] == "(" { depth += 1 }
                        if formatted[j] == ")" {
                            depth -= 1
                            if depth == 0 { close = j; break }
                        }
                        j = formatted.index(after: j)
                    }
                    if let close {
                        flush()
                        out.append((String(formatted[formatted.index(after: next)..<close]), .sup))
                        i = formatted.index(after: close)
                        continue
                    }
                } else if next < formatted.endIndex, formatted[next].isLetter || formatted[next].isNumber || formatted[next] == "∞" || formatted[next] == "*" || formatted[next] == "†" {
                    // Single character superscript: ^K, ^T, ^n, ^∞
                    flush()
                    out.append((String(formatted[next]), .sup))
                    i = formatted.index(after: next)
                    continue
                }
            }
            plain.append(ch)
            i = formatted.index(after: i)
        }
        flush()
        return out
    }

    // MARK: - Memoised Formatting

    /// `format` is pure, and a streaming reply re-formats every span it has already drawn on
    /// every token: the results are kept so a paragraph of math costs one pass per unique formula.
    nonisolated(unsafe) private static let formatCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4_000
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    private static func formatted(_ latex: String, context: Context) -> String {
        // A key longer than this costs more to hash than the formatting it saves.
        guard latex.utf8.count <= 2_048 else { return format(latex, context: context, depth: 0) }
        let key = ((context == .math ? "m\u{0}" : "p\u{0}") + latex) as NSString
        if let hit = formatCache.object(forKey: key) { return hit as String }
        let out = format(latex, context: context, depth: 0)
        formatCache.setObject(out as NSString, forKey: key, cost: latex.utf8.count * 2)
        return out
    }

    // MARK: - The Pipeline

    private static func format(_ latex: String, context: Context, depth: Int) -> String {
        guard depth < 6 else { return latex }
        var s = context == .math ? stripDelimiters(latex) : latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // Nothing TeX-ish: no commands to read, only spacing to fix in a formula.
        guard s.contains("\\") || s.contains("{") || s.contains("}") || s.contains("_") || s.contains("^") else {
            return context == .math ? spaceOperators(s) : s
        }

        let hasCommand = s.contains("\\")
        if hasCommand {
            // A matrix or an aligned block reads as its rows rather than as TeX source.
            if s.contains("\\begin{") { s = stripEnvironments(s) }
            s = s.replacingOccurrences(of: "\\LaTeX", with: "LaTeX")
            s = s.replacingOccurrences(of: "\\TeX", with: "TeX")
            // M_ {ghost} → M_{ghost}, M_\text{ghost} → M_{ghost}: a script's argument belongs to the script.
            s = normaliseScriptSpacing(s)
            s = liftScriptTextCommands(s)
            s = stripDelimiterCommands(s)
            s = replaceFontVariants(s, depth: depth)
            // Symbols go first, while every command name is still intact and still ended by a
            // non-letter. Any later pass inserts characters (an accent's mark, a numerator) and
            // a command substituted after it is glued into a name that does not exist:
            // \eta\mathbf{g} → "\etag", \log\frac{p}{q} → "\logp(x)/q(x)".
            if context == .math { s = s.replacingOccurrences(of: "\\\\", with: " ; ") }
            s = stripBarSpacing(s)
            s = replaceSymbolCommands(s)
            s = stripLayoutCommands(s)
            s = replaceStacking(s, context: context, depth: depth)
            s = replaceAccents(s, context: context, depth: depth)
            s = replaceFractions(s, context: context, depth: depth)
            s = replaceBinomials(s, context: context, depth: depth)
            s = replaceSquareRoots(s, context: context, depth: depth)
            s = unwrapTextCommands(s)
            s = replaceEscapes(s, context: context)
            s = replaceSpacingCommands(s)
        }

        if s.contains("_") || s.contains("^") {
            s = replaceScripts(s, context: context, depth: depth)
        }
        // Relations and binary operators are spaced in a formula; a sign is not an operator.
        if context == .math { s = spaceOperators(s) }
        s = tightenDelimiters(s)
        // Only a formula may lose its grouping braces; in prose they are the writer's.
        if context == .math {
            s = cleanBraces(s)
            s = s.replacing(/[ \t]{2,}/, with: " ")
            s = s.trimmingCharacters(in: .whitespaces)
        }
        if s.contains(literalUnderscore) { s = s.replacingOccurrences(of: literalUnderscore, with: "_") }
        return s
    }

    private static func stripDelimiters(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 4, s.hasPrefix("$$"), s.hasSuffix("$$") {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.count >= 4, s.hasPrefix("\\["), s.hasSuffix("\\]") {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.count >= 4, s.hasPrefix("\\("), s.hasSuffix("\\)") {
            s = String(s.dropFirst(2).dropLast(2))
        } else if s.count >= 2, s.hasPrefix("$"), s.hasSuffix("$") {
            s = String(s.dropFirst(1).dropLast(1))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `\begin{pmatrix}` … `\end{pmatrix}`: drop the environment, keep the cells, and let a row
    /// break read as a separator so a matrix is not one run-on line.
    private static func stripEnvironments(_ text: String) -> String {
        // A matrix's columns and a cases' conditions are separate fields; aligned & gathered
        // use & only to line up equations, so there it is not a separator at all.
        let cells = ["matrix", "cases", "array", "dcases", "rcases"]
        let named = text.firstMatch(of: /\\begin\{([A-Za-z*]+)\}/).map { String($0.1) } ?? ""
        let separator = cells.contains(where: { named.contains($0) }) ? " , " : " "
        var s = text.replacingOccurrences(of: "\\\\", with: " ; ")
        s = s.replacing(/\\begin\{[A-Za-z*]+\}/, with: "")
        s = s.replacing(/\\end\{[A-Za-z*]+\}/, with: "")
        s = s.replacingOccurrences(of: "&", with: separator)
        // The fields leave gaps where the alignment marks were.
        s = s.replacing(/[ \t]{2,}/, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func normaliseScriptSpacing(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "_ {", with: "_{")
        out = out.replacingOccurrences(of: "^ {", with: "^{")
        out = out.replacingOccurrences(of: "_ (", with: "_(")
        out = out.replacingOccurrences(of: "^ (", with: "^(")
        return out
    }

    /// `M_\text{ghost}` → `M_{ghost}`: the argument is a script body, not loose text.
    private static func liftScriptTextCommands(_ text: String) -> String {
        var s = text
        for cmd in textCommands {
            for marker in ["_", "^"] {
                s = s.replacingOccurrences(of: "\(marker) \(cmd)", with: "\(marker)\(cmd)")
                var searchStart = s.startIndex
                while searchStart < s.endIndex, let r = s.range(of: "\(marker)\(cmd)", range: searchStart..<s.endIndex) {
                    if let (content, next) = extractBracedContent(s, from: r.upperBound) {
                        let replacement = "\(marker){\(content)}"
                        s.replaceSubrange(r.lowerBound..<next, with: replacement)
                        searchStart = s.index(r.lowerBound, offsetBy: replacement.count, limitedBy: s.endIndex) ?? s.endIndex
                    } else {
                        searchStart = r.upperBound
                    }
                }
            }
        }
        return s
    }

    /// `\left(`, `\right]`, `\bigl\{` …: the delimiter is the character after the command.
    private static func stripDelimiterCommands(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\left.", with: "")
        s = s.replacingOccurrences(of: "\\right.", with: "")
        s = s.replacingOccurrences(of: "\\left\\{", with: "{")
        s = s.replacingOccurrences(of: "\\right\\}", with: "}")
        s = s.replacing(/\\\s*(?:left|right|bigl|bigr|Bigl|Bigr|biggl|biggr|Biggl|Biggr|big|Big|bigg|Bigg|middle)(?![a-zA-Z])/, with: "")
        return s
    }

    private static func replaceFontVariants(_ text: String, depth: Int) -> String {
        var s = text
        let variants: [(String, [Character: Character])] = [
            ("\\mathbb", blackboard), ("\\mathcal", mathcal), ("\\mathscr", mathcal)
        ]
        for (cmd, table) in variants {
            var searchStart = s.startIndex
            while searchStart < s.endIndex, let r = s.range(of: cmd, range: searchStart..<s.endIndex) {
                let after = r.upperBound
                if after >= s.endIndex { break }
                if let (content, next) = extractBracedContent(s, from: after) {
                    let mapped = String(content.map { table[$0] ?? $0 })
                    s.replaceSubrange(r.lowerBound..<next, with: mapped)
                    searchStart = s.index(r.lowerBound, offsetBy: mapped.count, limitedBy: s.endIndex) ?? s.endIndex
                } else if let mapped = table[s[after]] {
                    // The naked form models write: \mathcalN, \mathbbR
                    let end = s.index(after: after)
                    let mappedStr = String(mapped)
                    s.replaceSubrange(r.lowerBound..<end, with: mappedStr)
                    searchStart = s.index(r.lowerBound, offsetBy: mappedStr.count, limitedBy: s.endIndex) ?? s.endIndex
                } else {
                    searchStart = after
                }
            }
        }
        return s
    }

    private static func replaceAccents(_ text: String, context: Context, depth: Int) -> String {
        var s = text
        for (cmd, mark) in accents {
            let tag = "\\" + cmd
            var searchStart = s.startIndex
            while searchStart < s.endIndex, let r = s.range(of: tag, range: searchStart..<s.endIndex) {
                let after = r.upperBound
                // \hinge is not \hat: the command ends where the letters stop.
                if after < s.endIndex, s[after].isLetter {
                    searchStart = after
                    continue
                }
                guard let (raw, next) = extractArgument(s, from: after) else {
                    searchStart = after
                    continue
                }
                let inner = format(raw, context: context, depth: depth + 1)
                let replaced = accent(inner, mark: mark)
                s.replaceSubrange(r.lowerBound..<next, with: replaced)
                searchStart = s.index(r.lowerBound, offsetBy: replaced.count, limitedBy: s.endIndex) ?? s.endIndex
            }
        }
        return s
    }

    private static func accent(_ text: String, mark: Unicode.Scalar) -> String {
        var out = ""
        for ch in text {
            out.append(ch)
            if ch != " " { out.unicodeScalars.append(mark) }
        }
        return out
    }

    private static func replaceFractions(_ text: String, context: Context, depth: Int) -> String {
        var s = text
        let fracCmds = ["\\dfrac", "\\tfrac", "\\cfrac", "\\frac"]
        for cmd in fracCmds {
            var searchStart = s.startIndex
            while searchStart < s.endIndex, let r = s.range(of: cmd, range: searchStart..<s.endIndex) {
                if r.upperBound < s.endIndex, s[r.upperBound].isLetter {
                    searchStart = r.upperBound
                    continue
                }
                guard let (num, next1) = extractArgument(s, from: r.upperBound),
                      let (denom, next2) = extractArgument(s, from: next1) else {
                    searchStart = r.upperBound
                    continue
                }
                let n = group(format(num, context: context, depth: depth + 1))
                let d = group(format(denom, context: context, depth: depth + 1))
                let replacement = "\(n)/\(d)"
                s.replaceSubrange(r.lowerBound..<next2, with: replacement)
                searchStart = s.index(r.lowerBound, offsetBy: replacement.count, limitedBy: s.endIndex) ?? s.endIndex
            }
        }
        return s
    }

    private static func replaceBinomials(_ text: String, context: Context, depth: Int) -> String {
        var s = text
        let names = ["\\dbinom", "\\tbinom", "\\binom"]
        for name in names {
            var searchStart = s.startIndex
            while searchStart < s.endIndex, let r = s.range(of: name, range: searchStart..<s.endIndex) {
                if r.upperBound < s.endIndex, s[r.upperBound].isLetter {
                    searchStart = r.upperBound
                    continue
                }
                guard let (top, next1) = extractArgument(s, from: r.upperBound),
                      let (bottom, next2) = extractArgument(s, from: next1) else {
                    searchStart = r.upperBound
                    continue
                }
                let t = format(top, context: context, depth: depth + 1)
                let b = format(bottom, context: context, depth: depth + 1)
                let replacement = "C(\(t), \(b))"
                s.replaceSubrange(r.lowerBound..<next2, with: replacement)
                searchStart = s.index(r.lowerBound, offsetBy: replacement.count, limitedBy: s.endIndex) ?? s.endIndex
            }
        }
        return s
    }

    /// Commands that only lay a page out: a number tag, a label, a phantom box, a rule. They
    /// draw nothing inline, so dropping them is the render (leaving them shows TeX source).
    private static func stripLayoutCommands(_ text: String) -> String {
        var s = text
        for cmd in ["\\tag", "\\label", "\\phantom", "\\hphantom", "\\vphantom", "\\color", "\\cline", "\\hspace"] {
            var searchStart = s.startIndex
            while searchStart < s.endIndex, let r = s.range(of: cmd, range: searchStart..<s.endIndex) {
                if r.upperBound < s.endIndex, s[r.upperBound].isLetter {
                    searchStart = r.upperBound
                    continue
                }
                let end = extractBracedContent(s, from: r.upperBound)?.1 ?? r.upperBound
                s.replaceSubrange(r.lowerBound..<end, with: "")
                searchStart = r.lowerBound
            }
        }
        for cmd in ["\\hline", "\\nonumber", "\\notag", "\\noindent", "\\Huge", "\\huge", "\\large", "\\normalsize", "\\small", "\\footnotesize", "\\tiny"] {
            s = s.replacingOccurrences(of: cmd, with: "")
        }
        return s
    }

    /// Stacking and boxing: `\overset{a}{b}` draws b with a above it, `\boxed{x}` frames x —
    /// inline, the base is what can be read.
    private static func replaceStacking(_ text: String, context: Context, depth: Int) -> String {
        var s = text
        for cmd in ["\\overset", "\\underset", "\\stackrel"] {
            var searchStart = s.startIndex
            while searchStart < s.endIndex, let r = s.range(of: cmd, range: searchStart..<s.endIndex) {
                if r.upperBound < s.endIndex, s[r.upperBound].isLetter {
                    searchStart = r.upperBound
                    continue
                }
                guard let (_, next1) = extractBracedContent(s, from: r.upperBound),
                      let (base, next2) = extractBracedContent(s, from: next1) else {
                    searchStart = r.upperBound
                    continue
                }
                let replacement = format(base, context: context, depth: depth + 1)
                s.replaceSubrange(r.lowerBound..<next2, with: replacement)
                searchStart = s.index(r.lowerBound, offsetBy: replacement.count, limitedBy: s.endIndex) ?? s.endIndex
            }
        }
        var boxedStart = s.startIndex
        while boxedStart < s.endIndex, let r = s.range(of: "\\boxed", range: boxedStart..<s.endIndex) {
            if r.upperBound < s.endIndex, s[r.upperBound].isLetter {
                boxedStart = r.upperBound
                continue
            }
            guard let (content, next) = extractBracedContent(s, from: r.upperBound) else {
                boxedStart = r.upperBound
                continue
            }
            let replacement = format(content, context: context, depth: depth + 1)
            s.replaceSubrange(r.lowerBound..<next, with: replacement)
            boxedStart = s.index(r.lowerBound, offsetBy: replacement.count, limitedBy: s.endIndex) ?? s.endIndex
        }
        return s
    }

    private static func replaceSquareRoots(_ text: String, context: Context, depth: Int) -> String {
        var s = text
        var searchStart = s.startIndex
        while searchStart < s.endIndex, let r = s.range(of: "\\sqrt", range: searchStart..<s.endIndex) {
            guard !(r.upperBound < s.endIndex && s[r.upperBound].isLetter) else {
                searchStart = r.upperBound
                continue
            }
            var start = r.upperBound
            var index: String? = nil
            if start < s.endIndex, s[start] == "[",
               let close = s[start...].firstIndex(of: "]") {
                index = String(s[s.index(after: start)..<close])
                start = s.index(after: close)
            }
            guard let (content, next) = extractArgument(s, from: start) else {
                searchStart = r.upperBound
                continue
            }
            let formatted = format(content, context: context, depth: depth + 1)
            let body: String
            switch index?.trimmingCharacters(in: .whitespaces) {
            case nil, "2": body = "√(\(formatted))"
            case "3": body = "∛(\(formatted))"
            case "4": body = "∜(\(formatted))"
            case let other?: body = "√[\(other)](\(formatted))"
            }
            s.replaceSubrange(r.lowerBound..<next, with: body)
            searchStart = s.index(r.lowerBound, offsetBy: body.count, limitedBy: s.endIndex) ?? s.endIndex
        }
        return s
    }

    private static func unwrapTextCommands(_ text: String) -> String {
        var s = text
        for cmd in textCommands {
            var searchStart = s.startIndex
            while searchStart < s.endIndex, let r = s.range(of: cmd, range: searchStart..<s.endIndex) {
                guard !(r.upperBound < s.endIndex && s[r.upperBound].isLetter) else {
                    searchStart = r.upperBound
                    continue
                }
                guard let (content, next) = extractBracedContent(s, from: r.upperBound) else {
                    searchStart = r.upperBound
                    continue
                }
                s.replaceSubrange(r.lowerBound..<next, with: content)
                searchStart = s.index(r.lowerBound, offsetBy: content.count, limitedBy: s.endIndex) ?? s.endIndex
            }
        }
        return s
    }

    /// An escaped underscore is a literal one: `snake\_case` must not become a subscript.
    private static let literalUnderscore = "\u{E003}"

    private static func replaceEscapes(_ text: String, context: Context) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\_", with: literalUnderscore)
        s = s.replacingOccurrences(of: "\\|", with: "‖")
        s = s.replacing(/\\([%&#$\-])/) { match in String(match.1) }
        if context == .prose {
            // In prose the escaped brace is the writer's literal brace, not TeX grouping.
            s = s.replacingOccurrences(of: "\\{", with: "{")
            s = s.replacingOccurrences(of: "\\}", with: "}")
        }
        return s
    }

    private static func replaceSpacingCommands(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\,", with: "\u{2009}") // thin space
        s = s.replacingOccurrences(of: "\\:", with: "\u{2009}")
        s = s.replacingOccurrences(of: "\\;", with: "\u{2005}") // four-per-em space
        s = s.replacingOccurrences(of: "\\quad", with: "\u{2003}") // em space
        s = s.replacingOccurrences(of: "\\qquad", with: "\u{2003}\u{2003}")
        s = s.replacingOccurrences(of: "\\ ", with: " ")
        s = s.replacingOccurrences(of: "\\!", with: "") // negative thin space
        s = s.replacingOccurrences(of: "\\displaystyle", with: "")
        s = s.replacingOccurrences(of: "\\textstyle", with: "")
        s = s.replacingOccurrences(of: "\\limits", with: "")
        s = s.replacingOccurrences(of: "\\nolimits", with: "")
        return s
    }

    /// A vertical bar is a delimiter command with no distinct glyph, so its own spaces go with
    /// it: `\lvert x \rvert` → |x|, while a bare `a | b` keeps the spacing the model wrote.
    private static func stripBarSpacing(_ text: String) -> String {
        var s = text
        // The bar commands are replaced outright: leaving a space for the next letter would glue
        // the command to its argument (\lvert x → \lvertx, which is no command at all).
        let bars: [(cmd: String, glyph: String, opens: Bool)] = [
            ("\\lVert", "‖", true), ("\\rVert", "‖", false), ("\\Vert", "‖", true),
            ("\\lvert", "|", true), ("\\rvert", "|", false), ("\\vert", "|", true)
        ]
        for (cmd, glyph, opens) in bars {
            s = s.replacingOccurrences(of: opens ? cmd + " " : " " + cmd, with: glyph)
            s = s.replacingOccurrences(of: cmd, with: glyph)
        }
        return s
    }

    /// The names TeX sets as operators ("sin", "log", "max"): each takes a space from the
    /// operand before it and gives one to the command it takes as its argument.
    /// Commands that draw a relation: TeX spaces them on both sides wherever they stand.
    private static let relationCommands: Set<String> = ["mid", "nmid"]

    private static let operatorCommands: Set<String> = [
        "exp", "ln", "log", "lg", "sin", "cos", "tan", "sec", "csc", "cot",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "det", "dim", "gcd", "hom", "ker", "arg", "deg", "mod", "bmod",
        "lim", "liminf", "limsup", "max", "min", "inf", "sup"
    ]

    /// Digits, letters and closing brackets: what an operator sits next to.
    private static func isOperand(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == ")" || ch == "]" || ch == "}" || scriptGlyphs.contains(ch)
    }

    private static let scriptGlyphs: Set<Character> = Set("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼ⁿⁱˣʸᵗ₀₁₂₃₄₅₆₇₈₉₊₋₌ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ")

    /// Substitutes every command the tables know in one pass; an unknown command, and an
    /// escaped character (`\%`, `\|`), is left exactly as written.
    private static func replaceSymbolCommands(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "\\" else {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            let start = text.index(after: i)
            var end = start
            while end < text.endIndex, text[end].isASCII, text[end].isLetter { end = text.index(after: end) }
            let cmd = String(text[start..<end])
            guard end > start, let replacement = commandLookup[cmd] else {
                out.append(text[i])
                i = start
                continue
            }
            if relationCommands.contains(cmd) {
                if let last = out.last, isOperand(last) { out.append(" ") }
                out.append(replacement)
                if end < text.endIndex, isOperand(text[end]) { out.append(" ") }
                i = end
                continue
            }
            // "n\log n" is "n log n": an operator never touches its operand.
            if operatorCommands.contains(cmd), let last = out.last, isOperand(last) { out.append(" ") }
            out.append(replacement)
            // \log\frac{p}{q} draws the operator space in front of the fraction it takes.
            if operatorCommands.contains(cmd), end < text.endIndex, text[end] == "\\" {
                out.append("\u{2009}")
            }
            i = end
        }
        return out
    }

    /// Relations and binary operators set apart from their operands, as TeX spaces them: `x=1`
    /// reads "x = 1". A `-` or `+` with no operand before it is a sign and stays attached.
    private static func spaceOperators(_ text: String) -> String {
        guard text.contains(where: { operatorSpacing.contains($0) }) else { return text }
        var out = ""
        out.reserveCapacity(text.count + 8)
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            guard operatorSpacing.contains(ch) else {
                out.append(ch)
                i = text.index(after: i)
                continue
            }
            let next = text.index(after: i)
            let spaceBefore = out.last.map(isOperand) ?? false
            let spaceAfter = next < text.endIndex ? isOperand(text[next]) : false
            if ch == "-" || ch == "+" {
                // Binary only when there is an operand on both sides: e^(-x²) keeps its sign tight.
                if spaceBefore, spaceAfter { out.append(" "); out.append(ch); out.append(" ") }
                else { out.append(ch) }
            } else {
                if spaceBefore { out.append(" ") }
                out.append(ch)
                if spaceAfter { out.append(" ") }
            }
            i = next
        }
        return out
    }

    private static let operatorSpacing: Set<Character> = Set("=<>≤≥≠≈≡≅∝∈∉⊂⊆⊃⊇∪∩→⇒⟹⟺⟶↦←⇐↑↓⊕⊗±×÷·∓")

    // MARK: - Script Replacement (Subscripts & Superscripts)

    private static func replaceScripts(_ text: String, context: Context, depth: Int) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            guard c == "_" || c == "^" else {
                result.append(c)
                i = text.index(after: i)
                continue
            }
            let isSub = (c == "_")
            var next = text.index(after: i)
            guard next < text.endIndex else {
                result.append(c)
                i = next
                continue
            }

            // Tolerate the space models leave behind: M_ {ghost}, x_ 1.
            if text[next] == " " {
                let afterSpace = text.index(after: next)
                if afterSpace < text.endIndex { next = afterSpace }
            }

            if text[next] == "{" {
                // Script block: ^{abc} or _{abc}
                if let close = text[next...].firstIndex(of: "}") {
                    let raw = String(text[text.index(after: next)..<close])
                    result.append(script(raw, isSub: isSub, context: context, depth: depth))
                    i = text.index(after: close)
                    continue
                }
            } else if text[next] == "(" {
                // Parenthesised body: _(ghost) or ^(n+1)
                if let close = text[next...].firstIndex(of: ")") {
                    let raw = String(text[text.index(after: next)..<close])
                    result.append(script(raw, isSub: isSub, context: context, depth: depth))
                    i = text.index(after: close)
                    continue
                }
            } else {
                // Single character script: _2 or ^2 or _i
                let target = text[next]
                let nextNext = text.index(after: next)
                // A letter inside a longer word is a name, not a subscript (snake_case survives).
                let wordContinuation = context == .prose && target.isLetter
                    && nextNext < text.endIndex && text[nextNext].isLetter
                if !wordContinuation {
                    if let mapped = (isSub ? subDigits : superDigits)[target] {
                        result.append(mapped)
                        i = nextNext
                        continue
                    }
                    // No Unicode script form (∇_θ, x_q): never leave the marker bare in a formula.
                    if context == .math {
                        result.append(isSub ? "₍\(target)₎" : "^\(target)")
                        i = nextNext
                        continue
                    }
                }
            }
            result.append(c)
            i = text.index(after: i)
        }
        return result
    }

    /// A script's body, set as Unicode script characters where they exist and in a readable
    /// bracket form where they do not.
    private static func script(_ raw: String, isSub: Bool, context: Context, depth: Int) -> String {
        let inner = format(raw, context: context, depth: depth + 1)
        if let mapped = mapScriptContent(inner, isSub: isSub) { return mapped }
        if !isSub, inner.count == 1 { return "^\(inner)" }
        // Subscripts that cannot be Unicode (ghost, i,j) get real subscript parentheses, never
        // a raw underscore, which reads as markdown emphasis in the chat.
        return isSub ? "₍\(inner)₎" : "^(\(inner))"
    }

    private static func mapScriptContent(_ text: String, isSub: Bool) -> String? {
        let dict = isSub ? subDigits : superDigits
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            guard let mapped = dict[ch] else { return nil }
            out.append(mapped)
        }
        return out
    }

    // MARK: - Grouping

    /// `\frac{a}{b}` → a/b, but `\frac{1}{b c}` → 1/(b c): a compound side keeps its grouping.
    private static func group(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return t }
        if isFullyParenthesised(t) { return t }
        let compound = t.contains(where: { " /+-−×·÷=<>≤≥,".contains($0) })
        return compound ? "(\(t))" : t
    }

    /// Whether the text is already a group: `(a + b)` or `(a + b)²`, whose brackets do the
    /// grouping the fraction needs.
    private static func isFullyParenthesised(_ text: String) -> Bool {
        guard text.hasPrefix("("), text.count >= 2 else { return false }
        var depth = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "(" { depth += 1 }
            if text[i] == ")" {
                depth -= 1
                if depth == 0 {
                    let rest = text[text.index(after: i)...]
                    return rest.allSatisfy { "⁰¹²³⁴⁵⁶⁷⁸⁹ⁿⁱˣʸᵗ⁺⁻⁼₀₁₂₃₄₅₆₇₈₉₊₋₌′".contains($0) }
                }
            }
            i = text.index(after: i)
        }
        return false
    }

    // MARK: - Argument Extraction

    /// The `{...}` at `start` (after optional whitespace), balanced, with the index just past it.
    private static func extractBracedContent(_ text: String, from start: String.Index) -> (String, String.Index)? {
        var i = start
        while i < text.endIndex && text[i].isWhitespace { i = text.index(after: i) }
        guard i < text.endIndex, text[i] == "{" else { return nil }
        var depth = 0
        let contentStart = text.index(after: i)
        var curr = i
        while curr < text.endIndex {
            if text[curr] == "{" { depth += 1 }
            else if text[curr] == "}" {
                depth -= 1
                if depth == 0 { return (String(text[contentStart..<curr]), text.index(after: curr)) }
            }
            curr = text.index(after: curr)
        }
        return nil
    }

    /// A command's argument: `{...}`, or TeX's one-token form, so `\frac12` and `\vec v` read too.
    private static func extractArgument(_ text: String, from start: String.Index) -> (String, String.Index)? {
        if let braced = extractBracedContent(text, from: start) { return braced }
        var i = start
        while i < text.endIndex && text[i].isWhitespace { i = text.index(after: i) }
        guard i < text.endIndex else { return nil }
        guard text[i] != "{", text[i] != "}" else { return nil }
        // A single token: one character, or one whole command (\frac\alpha\beta).
        if text[i] == "\\" {
            var j = text.index(after: i)
            while j < text.endIndex && text[j].isLetter { j = text.index(after: j) }
            guard j > text.index(after: i) else { return nil }
            return (String(text[i..<j]), j)
        }
        guard text[i].isLetter || text[i].isNumber else { return nil }
        let end = text.index(after: i)
        return (String(text[i..<end]), end)
    }

    /// TeX swallows the space either side of a bracket command (`\langle x \rangle` draws
    /// ⟨x⟩), so the space the model typed is not a space in the maths.
    private static func tightenDelimiters(_ text: String) -> String {
        var s = text
        for open in ["⟨", "⌈", "⌊", "⌜", "⌞"] {
            s = s.replacingOccurrences(of: open + " ", with: open)
        }
        for close in ["⟩", "⌉", "⌋", "⌝", "⌟"] {
            s = s.replacingOccurrences(of: " " + close, with: close)
        }
        return s
    }

    private static func cleanBraces(_ text: String) -> String {
        var s = text
        // Temporarily protect escaped braces \{ and \}
        let openMarker = "\u{E001}"
        let closeMarker = "\u{E002}"
        s = s.replacingOccurrences(of: "\\{", with: openMarker)
        s = s.replacingOccurrences(of: "\\}", with: closeMarker)

        // Strip unescaped TeX syntax grouping braces: {xyz} -> xyz
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")

        // Restore escaped braces
        s = s.replacingOccurrences(of: openMarker, with: "{")
        s = s.replacingOccurrences(of: closeMarker, with: "}")
        return s
    }

    // MARK: - Pandoc / CommonMark Inline Math Detection

    public struct InlineSpan: Equatable, Sendable {
        /// What opened the span: `$…$`, `\(…\)`, `$$…$$` or `\[…\]`.
        public enum Delimiter: Sendable, Equatable {
            case dollar, parentheses, doubleDollar, bracket
        }

        public var range: Range<String.Index>
        public var equation: String
        public var delimiter: Delimiter

        public var isDelimitedWithParentheses: Bool { delimiter == .parentheses }
        /// Display math written inside a paragraph rather than on a line of its own.
        public var isDisplay: Bool { delimiter == .doubleDollar || delimiter == .bracket }

        public init(range: Range<String.Index>, equation: String, delimiter: Delimiter = .dollar) {
            self.range = range
            self.equation = equation
            self.delimiter = delimiter
        }

        public init(range: Range<String.Index>, equation: String, isDelimitedWithParentheses: Bool) {
            self.init(range: range, equation: equation, delimiter: isDelimitedWithParentheses ? .parentheses : .dollar)
        }
    }

    /// Finds all inline math spans (`$...$`, `\(...\)`, `$$...$$`, `\[...\]`) conforming to
    /// Pandoc / CommonMark math rules. Excludes currency expressions, escaped dollars (`\$`),
    /// inline code spans, and multiline spans.
    public static func findInlineMath(in text: String) -> [InlineSpan] {
        var spans: [InlineSpan] = []
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]

            // `code`: LaTeX inside an inline code span is code, and is never touched.
            if c == "`" {
                var run = 1
                var j = text.index(after: i)
                while j < text.endIndex, text[j] == "`" { run += 1; j = text.index(after: j) }
                let fence = String(repeating: "`", count: run)
                if let close = text.range(of: fence, range: j..<text.endIndex) {
                    i = close.upperBound
                } else {
                    i = j
                }
                continue
            }

            // \( ... \) and \[ ... \]
            if c == "\\", !isEscaped(text, at: i) {
                let next = text.index(after: i)
                if next < text.endIndex, text[next] == "(" || text[next] == "[" {
                    let closer = text[next] == "(" ? "\\)" : "\\]"
                    let contentStart = text.index(after: next)
                    if let close = text.range(of: closer, range: contentStart..<text.endIndex) {
                        let equation = String(text[contentStart..<close.lowerBound])
                        if !equation.isEmpty, !equation.contains("\n") {
                            spans.append(InlineSpan(
                                range: i..<close.upperBound,
                                equation: equation,
                                delimiter: text[next] == "(" ? .parentheses : .bracket
                            ))
                            i = close.upperBound
                            continue
                        }
                    }
                }
                i = text.index(after: i)
                continue
            }

            if c == "$" {
                // Ignore if escaped: \$ (unless preceded by an even number of backslashes)
                if isEscaped(text, at: i) {
                    i = text.index(after: i)
                    continue
                }

                let next = text.index(after: i)
                // $$ display math written inside a paragraph
                if next < text.endIndex, text[next] == "$" {
                    let contentStart = text.index(after: next)
                    if let close = text.range(of: "$$", range: contentStart..<text.endIndex) {
                        let equation = String(text[contentStart..<close.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !equation.isEmpty, !equation.contains("\n") {
                            spans.append(InlineSpan(range: i..<close.upperBound, equation: equation, delimiter: .doubleDollar))
                            i = close.upperBound
                            continue
                        }
                    }
                    i = contentStart
                    continue
                }

                // Rule: Opening $ must NOT be followed by whitespace
                if next < text.endIndex, text[next].isWhitespace {
                    i = next
                    continue
                }

                // Rule: Opening $ must NOT be preceded by an alphanumeric character (e.g. name$var),
                // unless a group opens right after it: models write Var$(X)$ and f$(x)$.
                if i > text.startIndex {
                    let prev = text[text.index(before: i)]
                    if prev.isLetter || prev.isNumber {
                        let follow: Character? = next < text.endIndex ? text[next] : nil
                        let opensGroup = follow == "(" || follow == "[" || follow == "{" || follow == "\\"
                        if !opensGroup {
                            i = next
                            continue
                        }
                    }
                }

                // Look for closing $
                var j = next
                var foundClosing: String.Index? = nil
                while j < text.endIndex {
                    if text[j] == "\n" { break } // inline math cannot span across lines
                    if text[j] == "$" && !isEscaped(text, at: j) {
                        // Rule: Closing $ must NOT be preceded by whitespace
                        let beforeClose = text[text.index(before: j)]
                        if beforeClose.isWhitespace { break }
                        // Rule: Closing $ must NOT be followed by a digit ($5 to $10 is currency)
                        let afterClose = text.index(after: j)
                        if afterClose < text.endIndex, text[afterClose].isNumber { break }
                        foundClosing = j
                        break
                    }
                    j = text.index(after: j)
                }

                if let close = foundClosing {
                    let equation = String(text[next..<close])
                    if !equation.isEmpty {
                        // Final sanity check: if the content is just a pure price number like "5" or "10.50", skip
                        if !isPurePrice(equation) {
                            let end = text.index(after: close)
                            spans.append(InlineSpan(range: i..<end, equation: equation, delimiter: .dollar))
                            i = end
                            continue
                        }
                    }
                }
            }

            i = text.index(after: i)
        }

        return spans
    }

    private static func isEscaped(_ text: String, at index: String.Index) -> Bool {
        var count = 0
        var cur = index
        while cur > text.startIndex {
            cur = text.index(before: cur)
            if text[cur] == "\\" { count += 1 } else { break }
        }
        return count % 2 != 0
    }

    private static func isPurePrice(_ str: String) -> Bool {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains(".") || trimmed.contains(",") else { return false }
        return trimmed.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
    }
}
