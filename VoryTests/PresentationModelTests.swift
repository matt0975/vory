import Foundation
import SwiftUI
import Testing
@testable import Vory
@testable import VoryCore

/// Every sheet, full-screen cover, popover and context-menu preview in the app's views hands
/// its content the app's model itself (`withAppModel()`). The iPhone app on a Mac crashed as a
/// sheet came up whose content found no AppModel in the environment it was given (1.3 (5):
/// "No Observable object of type AppModel found", in the sheet's hosting controller), and a
/// presentation added later without it would bring that back.
@MainActor @Suite struct PresentationModelTests {
    /// A view that needs the model from its environment, as most sheets' content does.
    private struct ModelProbe: View {
        @Environment(AppModel.self) private var model
        static var seen: AppModel?
        var body: some View {
            let _ = { Self.seen = model }()
            Color.clear.frame(width: 2, height: 2)
        }
    }

    @Test func theModifierGivesTheContentTheModelWithNothingAbove() {
        ModelProbe.seen = nil
        // Drawn on its own, with no environment from any app view above it: what a
        // presentation's content has when the presenter's environment did not reach it.
        let renderer = ImageRenderer(content: ModelProbe().withAppModel())
        _ = renderer.cgImage
        #expect(ModelProbe.seen === AppModel.shared)
    }

    @Test func everyPresentationInTheAppsViewsHandsItsContentTheModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Vory")
        let files = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }, "the app's sources are not readable here")
        try #require(!files.isEmpty, "no Swift files under \(views.path)")
        var found = 0
        var missing: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for p in PresentationScan.presentations(in: source) {
                found += 1
                if !p.content.contains("withAppModel()") { missing.append("\(file.lastPathComponent):\(p.line) \(p.kind)") }
            }
        }
        // The scan itself has to see them: the app has dozens.
        #expect(found > 30, "the scan found only \(found) presentations")
        #expect(missing.isEmpty, "presentations whose content does not get the model: \(missing.joined(separator: ", "))")
    }

    @Test func theScanFindsTheContentOfEachKindOfPresentation() {
        let source = """
        struct V: View {
            var body: some View {
                // .sheet(isPresented: $commented) { Nope() }
                Text("a .sheet( in a string { }")
                    .sheet(isPresented: Binding(get: { a && b }, set: { _ in })) { One().withAppModel() }
                    .sheet(item: $x, onDismiss: { done() }) { item in
                        if let r { Two(r) }
                    }
                    .fullScreenCover(isPresented: $c) { Three(f: { $0 }).withAppModel() }
                    .popover(isPresented: $p, arrowEdge: .bottom) { Four("}") }
                    .contextMenu { Button("x") {} } preview: { Five().withAppModel() }
            }
        }
        """
        let found = PresentationScan.presentations(in: source)
        #expect(found.map(\.kind) == ["sheet", "sheet", "fullScreenCover", "popover", "preview"])
        #expect(found.map { $0.content.contains("withAppModel()") } == [true, false, true, false, true])
        #expect(found[1].content.contains("Two(r)"))
        #expect(found.map(\.line) == [5, 6, 9, 10, 11])
    }
}

/// Finds the content closures of the presentations in a Swift source: `.sheet(…) { … }`,
/// `.fullScreenCover(…) { … }`, `.popover(…) { … }` and a context menu's `preview: { … }`.
/// Comments and the insides of strings are blanked first, so a brace or a parenthesis in a
/// string does not throw the matching off and a commented-out sheet is not counted.
enum PresentationScan {
    struct Found { var kind: String; var line: Int; var content: String }

    static func presentations(in source: String) -> [Found] {
        let code = Array(blanked(source))
        var out: [Found] = []
        var i = 0
        while i < code.count {
            if let kind = modifier(at: i, in: code) {
                // The arguments, then the trailing closure that is the content.
                let open = i + kind.count + 1
                guard let close = matching(code, from: open, open: "(", close: ")") else { break }
                var j = close + 1
                while j < code.count, code[j] == " " || code[j] == "\n" { j += 1 }
                if j < code.count, code[j] == "{", let end = matching(code, from: j, open: "{", close: "}") {
                    out.append(Found(kind: kind, line: line(of: i, in: code), content: String(code[j...end])))
                } else {
                    // `content:` given inside the parentheses.
                    out.append(Found(kind: kind, line: line(of: i, in: code), content: String(code[open...close])))
                }
                i = open
                continue
            }
            if code[i] == "p", String(code[i..<min(code.count, i + 8)]) == "preview:", i > 0, !isIdentifier(code[i - 1]) {
                var j = i + 8
                while j < code.count, code[j] == " " || code[j] == "\n" { j += 1 }
                if j < code.count, code[j] == "{", let end = matching(code, from: j, open: "{", close: "}") {
                    out.append(Found(kind: "preview", line: line(of: i, in: code), content: String(code[j...end])))
                }
                i += 8
                continue
            }
            i += 1
        }
        return out
    }

    private static let kinds = ["fullScreenCover", "popover", "sheet"]

    /// The modifier's name when `.name(` starts at `i`.
    private static func modifier(at i: Int, in code: [Character]) -> String? {
        guard code[i] == "." else { return nil }
        for k in kinds {
            let end = i + 1 + k.count
            guard end < code.count, code[end] == "(" else { continue }
            if String(code[(i + 1)..<end]) == k { return k }
        }
        return nil
    }

    private static func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private static func matching(_ code: [Character], from start: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        var i = start
        while i < code.count {
            if code[i] == open { depth += 1 } else if code[i] == close { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    private static func line(of index: Int, in code: [Character]) -> Int {
        code[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The source with comments and the contents of string literals (interpolations too)
    /// turned into spaces, line breaks kept.
    static func blanked(_ source: String) -> String {
        let s = Array(source)
        var out = s
        var i = 0
        func blank(_ k: Int) { if out[k] != "\n" { out[k] = " " } }
        while i < s.count {
            let c = s[i]
            let next: Character? = i + 1 < s.count ? s[i + 1] : nil
            if c == "/", next == "/" {
                while i < s.count, s[i] != "\n" { blank(i); i += 1 }
            } else if c == "/", next == "*" {
                var depth = 0
                repeat {
                    if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" { depth += 1; blank(i); blank(i + 1); i += 2; continue }
                    if s[i] == "*", i + 1 < s.count, s[i + 1] == "/" { depth -= 1; blank(i); blank(i + 1); i += 2; continue }
                    blank(i); i += 1
                } while i < s.count && depth > 0
            } else if c == "\"" {
                let triple = i + 2 < s.count && s[i + 1] == "\"" && s[i + 2] == "\""
                i += triple ? 3 : 1
                while i < s.count {
                    if s[i] == "\\" {
                        blank(i)
                        if i + 1 < s.count, s[i + 1] == "(" {
                            // An interpolation: blanked up to its closing parenthesis.
                            var depth = 0
                            i += 1
                            repeat {
                                if s[i] == "(" { depth += 1 } else if s[i] == ")" { depth -= 1 }
                                blank(i); i += 1
                            } while i < s.count && depth > 0
                        } else {
                            if i + 1 < s.count { blank(i + 1) }
                            i += 2
                        }
                        continue
                    }
                    if triple, s[i] == "\"", i + 2 < s.count, s[i + 1] == "\"", s[i + 2] == "\"" { i += 3; break }
                    if !triple, s[i] == "\"" { i += 1; break }
                    if !triple, s[i] == "\n" { break }
                    blank(i); i += 1
                }
            } else {
                i += 1
            }
        }
        return String(out)
    }
}
