#if os(macOS)
import Foundation
import Testing
@testable import Vory

/// Saving a picture to Downloads never writes over a file that is there.
@Suite struct MacMediaSaveTests {
    @Test func aTakenNameGetsANumberBeforeItsExtension() {
        let taken: Set<String> = ["shot.png", "shot 2.png", "notes", "notes 2"]
        #expect(MediaSave.uniqueName("fresh.png") { taken.contains($0) } == "fresh.png")
        #expect(MediaSave.uniqueName("shot.png") { taken.contains($0) } == "shot 3.png")
        #expect(MediaSave.uniqueName("notes") { taken.contains($0) } == "notes 3")
        #expect(MediaSave.uniqueName("a.b.jpg") { $0 == "a.b.jpg" } == "a.b 2.jpg")
    }

    @Test func savingTwiceMakesTwoFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vory-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: source)
        // The same rule the Downloads save uses, exercised against a folder of our own.
        let first = MediaSave.uniqueName("pic.png") { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(first))
        let second = MediaSave.uniqueName("pic.png") { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        #expect(first == "pic.png" && second == "pic 2.png")
    }
}
#endif
