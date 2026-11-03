import SwiftUI

/// Open-source code that ships inside Vory, each with its licence word for word as the project
/// ships it, read from Acknowledgements.json in the app bundle. KaTeX is first: it draws the maths
/// in replies.
struct Acknowledgement: Decodable, Identifiable, Equatable {
    var name: String
    var version: String
    var url: URL
    var licence: String
    /// The notice as it came, its line breaks and all.
    var text: String
    var id: String { name }

    /// The notice as paragraphs to read: each paragraph's hard-wrapped lines joined, so it reflows
    /// at every text size instead of breaking where the file did. A rule of dashes is drawing, not
    /// words, and is left out; a short line in capitals over the rest of its paragraph (PREAMBLE,
    /// DISCLAIMER) is a heading and stands on its own.
    var paragraphs: [String] {
        text.components(separatedBy: "\n\n").flatMap { block -> [String] in
            var lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "-" } }
            guard let first = lines.first else { return [] }
            var out: [String] = []
            if lines.count > 1, first.split(separator: " ").count <= 3,
               first.contains(where: \.isLetter), !first.contains(where: \.isLowercase) {
                out.append(first)
                lines.removeFirst()
            }
            return out + [lines.joined(separator: " ")]
        }
    }

    /// The bundle's list in its order; empty if the file is missing or unreadable.
    static func bundled(in bundle: Bundle = .main) -> [Acknowledgement] {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Acknowledgement].self, from: data)
        else { return [] }
        return list
    }
}

/// Settings › About › Acknowledgements: one section per project, its name, version and licence
/// (a link to its site), then the notice in full.
struct AcknowledgementsView: View {
    private let list = Acknowledgement.bundled()

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Acknowledgements", symbol: "doc.text", color: .gray,
                                  description: "Open-source code inside Vory, and the licence each comes under.")
            if list.isEmpty {
                Section { Text("The licences couldn't be read.").foregroundStyle(.secondary) }
            }
            ForEach(list) { item in
                Section {
                    Link(destination: item.url) {
                        LabeledContent { Text(item.licence).foregroundStyle(.secondary) }
                               label: { Label("\(item.name) \(item.version)", systemImage: "safari") }
                            #if os(macOS)
                            // The Mac's form draws a link row only as tall as its text (16 pt): at least 28 pt,
                            // the Mac's comfortable target, all of it a place to click.
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                            #endif
                    }
                    .accessibilityLabel("\(item.name) \(item.version), \(item.licence)")
                    // One element per paragraph, so VoiceOver reads the notice a paragraph at a time.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.footnote)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }
        }
        .untitledPage()
    }
}
