import Foundation
import AVFAudio
import Testing
@testable import VoryCore

/// What of a reply is read aloud.
@Suite struct SpokenTextTests {
    @Test func markdownBecomesWordsAndBlocksBecomeNotes() {
        let reply = """
        ## What I found

        `/var/log` is using **4.2 GB**, almost all of it [rotated files](https://example.com) older than 90 days:

        - `nginx/access.log.*` — 2.1 GB
        - postgres logs, *the oldest from March*

        ```bash
        find /var/log -name '*.log.*' -mtime +90 -delete
        ```

        | Directory | Size |
        |---|---|
        | nginx | 2.1 GB |

        ```html
        <canvas id="c"></canvas>
        ```

        Say the word and I'll run it.
        """
        let spoken = SpokenText.forSpeech(reply)
        #expect(spoken.hasPrefix("What I found. /var/log is using 4.2 GB, almost all of it rotated files older than 90 days:"))
        #expect(spoken.contains("nginx/access.log.* — 2.1 GB."))
        #expect(spoken.contains("postgres logs, the oldest from March."))
        #expect(spoken.contains(SpokenText.codeOmitted) && spoken.contains(SpokenText.tableOmitted) && spoken.contains(SpokenText.cardOmitted))
        #expect(!spoken.contains("```") && !spoken.contains("**") && !spoken.contains("](") && !spoken.contains("|"))
        #expect(spoken.hasSuffix("Say the word and I'll run it."))
    }

    @Test func anUnclosedFenceAndImagesAreHandled() {
        #expect(SpokenText.forSpeech("Here:\n```python\nprint(1)") == "Here: " + SpokenText.codeOmitted)
        #expect(SpokenText.forSpeech("See ![the chart](x.png) and ![](y.png).") == "See the chart and an image.")
        #expect(SpokenText.forSpeech("") == "")
    }

    @Test func sentencesAreCutForOneAtATimeSynthesisWithShortOnesJoined() {
        let s = SpokenText.sentences("Yes. The index is built, and the export runs in 40 seconds now. Shall I set logrotate to eight? Done!")
        #expect(s == ["Yes. The index is built, and the export runs in 40 seconds now.", "Shall I set logrotate to eight?", "Done!"])
        #expect(SpokenText.sentences("no end") == ["no end"])
    }
}

/// Where speech goes, by the Speech setting.
@Suite struct VoiceRoutingTests {
    @Test func theSettingDecidesAndAutomaticRemembersARefusal() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(VoiceRouting.route(for: .device, gatewayConnected: true, gatewayUnableUntil: nil, now: now) == .device)
        #expect(VoiceRouting.route(for: .gateway, gatewayConnected: false, gatewayUnableUntil: now.addingTimeInterval(60), now: now) == .gateway)
        #expect(VoiceRouting.route(for: .automatic, gatewayConnected: true, gatewayUnableUntil: nil, now: now) == .gateway)
        #expect(VoiceRouting.route(for: .automatic, gatewayConnected: false, gatewayUnableUntil: nil, now: now) == .device)
        #expect(VoiceRouting.route(for: .automatic, gatewayConnected: true, gatewayUnableUntil: now.addingTimeInterval(60), now: now) == .device)
        #expect(VoiceRouting.route(for: .automatic, gatewayConnected: true, gatewayUnableUntil: now.addingTimeInterval(-1), now: now) == .gateway)
    }

    @Test func onlyAMissingProviderCountsAsNoProvider() {
        #expect(VoiceRouting.isNoProvider(HermesAPIError.http(status: 400, detail: "No STT provider configured")))
        #expect(VoiceRouting.isNoProvider(HermesAPIError.http(status: 500, detail: "ElevenLabs API key missing")))
        #expect(VoiceRouting.isNoProvider(HermesAPIError.http(status: 404, detail: "Not Found")))
        #expect(!VoiceRouting.isNoProvider(HermesAPIError.http(status: 413, detail: "Audio recording is too large")))
        #expect(!VoiceRouting.isNoProvider(HermesAPIError.transport("timed out")))
        #expect(VoiceRouting.label(route: .gateway, provider: "whisper") == "Gateway (whisper)")
        #expect(VoiceRouting.label(route: .device, provider: "x") == "On this device")
    }
}

/// The speak-stream socket's frames, both ways.
@Suite struct SpeakStreamTests {
    @Test func serverFramesParse() {
        #expect(SpeakStreamFrame.parse(text: #"{"type": "start", "sample_rate": 22050, "channels": 1}"#) == .start(sampleRate: 22050, channels: 1))
        #expect(SpeakStreamFrame.parse(text: #"{"type": "start"}"#) == .start(sampleRate: 24000, channels: 1))
        #expect(SpeakStreamFrame.parse(text: #"{"type": "end"}"#) == .end)
        #expect(SpeakStreamFrame.parse(text: #"{"type": "fallback"}"#) == .fallback)
        #expect(SpeakStreamFrame.parse(text: "not json") == nil)
        #expect(SpeakStreamFrame.parse(data: Data([1, 2, 3])) == .pcm(Data([1, 2, 3])))
    }

    @Test func clientFramesAreTheServersShape() {
        #expect(SpeakStreamFrame.clientText("Hello, \"world\"\n") == #"{"text": "Hello, \"world\"\n"}"#)
        #expect(SpeakStreamFrame.clientDone == #"{"done": true}"# && SpeakStreamFrame.clientStop == #"{"stop": true}"#)
    }

    @Test func speechDataURLsDecodeAndChunksKnowTheirLength() {
        let wav = Data([0x52, 0x49, 0x46, 0x46])
        let url = GatewayVoiceAPI.dataURL(wav, mimeType: "audio/wav")
        #expect(url.hasPrefix("data:audio/wav;base64,"))
        #expect(GatewayVoiceAPI.Speech.decode(dataURL: url) == wav)
        #expect(GatewayVoiceAPI.Speech.decode(dataURL: "data:audio/wav,plain") == nil)
        let chunk = AudioChunk(sampleRate: 24000, channels: 1, isFloat32: false, data: Data(count: 48000))
        #expect(chunk.frameCount == 24000 && chunk.seconds == 1)
        #expect(chunk.pcmBuffer()?.frameLength == 24000)
    }
}
