import AVFAudio
import Foundation
import Testing
@testable import Vory

@Suite struct ClipTimeTests {
    @Test func formatsThePosition() {
        #expect(ClipTime.string(0) == "0:00")
        #expect(ClipTime.string(7.4) == "0:07")
        #expect(ClipTime.string(67) == "1:07")
        #expect(ClipTime.string(3599.9) == "59:59")
        #expect(ClipTime.string(3600) == "1:00:00")
        #expect(ClipTime.string(.nan) == "0:00")
        #expect(ClipTime.string(-3) == "0:00")
    }
}

@MainActor @Suite struct ClipPlayerTests {
    /// A 0.6 s WAV written to a temp file; the player loads its duration, plays it, stops.
    @Test func aClipLoadsItsDurationAndPlays() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 9600))
            buffer.frameLength = 9600
            try file.write(from: buffer)
        }
        ClipPlayer.shared.toggle(ref: "t", file: url, name: "t.wav")
        let deadline = ContinuousClock.now + .seconds(2)
        while !(0.55...0.75).contains(ClipPlayer.shared.duration), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((0.55...0.75).contains(ClipPlayer.shared.duration))
        #expect(ClipPlayer.shared.isPlaying)
        ClipPlayer.shared.pause()
        #expect(!ClipPlayer.shared.isPlaying)
        ClipPlayer.shared.stop()
        #expect(ClipPlayer.shared.refID == nil)
        #expect(ClipPlayer.shared.current == 0)
        try? FileManager.default.removeItem(at: url)
    }
}