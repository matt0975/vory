import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// The player one play at a time: a second `play` while the first still drains waits for it
/// (it used to throw the first's queue away and take over its finish, so Live's next turn could
/// start over the end of the last).
@Suite(.serialized) struct VoicePlayerTests {
    /// 100 ms of silence at 24 kHz, int16 mono.
    private var quiet: AudioChunk { AudioChunk(sampleRate: 24000, channels: 1, isFloat32: false, data: Data(count: 2400 * 2)) }

    @MainActor @Test func aSecondPlayWaitsForTheFirstToFinish() async throws {
        let player = VoicePlayer()
        let (first, c1) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        let (second, c2) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        c1.yield(quiet); c1.yield(quiet)
        c2.yield(quiet); c2.finish()
        let order = Order()
        let one = Task { @MainActor in try await player.play(first); order.add("first done") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.isPlaying, "the first play is on, its stream still open")
        let two = Task { @MainActor in try await player.play(second); order.add("second done") }
        try await Task.sleep(for: .milliseconds(400))
        #expect(order.lines.isEmpty, "neither has finished: the second is waiting its turn, not over the first")
        #expect(player.isPlaying)
        c1.finish()
        try await one.value
        try await two.value
        #expect(order.lines == ["first done", "second done"])
        #expect(!player.isPlaying)
    }

    @MainActor @Test func stopEndsAPlayWhoseStreamIsStillOpen() async throws {
        let player = VoicePlayer()
        let (stream, c) = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        c.yield(quiet)
        let play = Task { @MainActor in try await player.play(stream) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.isPlaying)
        player.stop()
        #expect(!player.isPlaying)
        c.finish()
        try await play.value
    }

    @MainActor final class Order { var lines: [String] = []; func add(_ s: String) { lines.append(s) } }
}
