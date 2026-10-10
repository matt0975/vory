import AVFAudio
import Foundation
import Testing
@testable import Vory

/// The ears while the bot speaks: the echo of its own voice (loud on a speaker, cancelled but
/// not gone) sets a floor, and only sound well above it counts as the person. Without the
/// guard the bot interrupted and answered itself (#280).
@Suite struct PlaybackGuardTests {
    /// A buffer of steady tone at the given loudness, about 40 ms at 48 kHz.
    private func buffer(dB: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames: AVAudioFrameCount = 2048
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        let amplitude = powf(10, dB / 20)
        let data = b.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = amplitude * (i % 2 == 0 ? 1 : -1) }
        return b
    }

    private func feed(_ pipe: InputPipe, dB: Float, buffers: Int) {
        for _ in 0..<buffers { pipe.ingest(buffer(dB: dB)) }
    }

    @Test func theBotsOwnVoiceDoesNotCountWhileItSpeaksButThePersonDoes() {
        let pipe = InputPipe()
        pipe.reset()
        // Loud enough that the plain loudness gate would call it speech.
        feed(pipe, dB: -20, buffers: 10)
        #expect(pipe.snapshot(detectorActive: false).speechNow, "without the guard, a loud sound is speech")

        // The bot starts speaking: the same loudness is its echo, and the floor climbs to it.
        pipe.setGuardingPlayback(true)
        feed(pipe, dB: -20, buffers: 120)
        #expect(!pipe.snapshot(detectorActive: false).speechNow, "the echo counted as the person")

        // The person talks over it, clearly louder: that counts within a few buffers.
        feed(pipe, dB: -6, buffers: 6)
        #expect(pipe.snapshot(detectorActive: false).speechNow, "a voice well above the echo did not count")

        // The bot stops: the guard goes, and the gate is the plain one again.
        pipe.setGuardingPlayback(false)
        feed(pipe, dB: -20, buffers: 5)
        #expect(pipe.snapshot(detectorActive: false).speechNow)
    }

    @Test func aPauseInTheBotsSpeechLowersTheFloor() {
        let pipe = InputPipe()
        pipe.reset()
        pipe.setGuardingPlayback(true)
        feed(pipe, dB: -20, buffers: 120)
        // Quiet for about two seconds: the floor falls, and a voice at the old echo level is heard.
        feed(pipe, dB: -70, buffers: 50)
        feed(pipe, dB: -20, buffers: 6)
        #expect(pipe.snapshot(detectorActive: false).speechNow, "after a pause, a voice at the old echo level did not count")
    }
}
