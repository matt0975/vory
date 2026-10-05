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

    @Test func frontMatterIsNotRead() {
        #expect(SpokenText.forSpeech("---\nSummary: x\ntitle: y\n---\nHello there.") == "Hello there.")
        #expect(SpokenText.forSpeech("---\nHello there.") == "Hello there.")
        #expect(SpokenText.forSpeech("Plain first.\n---\nkey: v\n---\nAfter.") == "Plain first. key: v After.")
    }

    @Test func picturesAreShownNotRead() {
        // A MEDIA: reference and a bare image path say nothing; the words around them stay.
        let reply = "Here is the disk use before and after:\nMEDIA:/home/x/.hermes/images/disk.png\n/tmp/shot.png\nDone."
        #expect(SpokenText.forSpeech(reply) == "Here is the disk use before and after: Done.")
        #expect(SpokenText.forSpeech("See MEDIA:/a/b.png now.") == "See now.")
    }

    @Test func anUnclosedFenceAndImagesAreHandled() {
        #expect(SpokenText.forSpeech("Here:\n```python\nprint(1)") == "Here: " + SpokenText.codeOmitted)
        #expect(SpokenText.forSpeech("See ![the chart](x.png) and ![](y.png).") == "See the chart and an image.")
        #expect(SpokenText.forSpeech("") == "")
    }

    @Test func aTableWithoutOuterPipesIsOneNoteAndAPipeInProseIsStillSaid() {
        // The app renders tables written without outer pipes (PR #133); the voice skips them too.
        #expect(SpokenText.forSpeech("Sizes:\n\na | b\n--|--\n1 | 2\n\nDone.") == "Sizes: " + SpokenText.tableOmitted + " Done.")
        let prose = SpokenText.forSpeech("Either A | or B, your call.\nNext.")
        #expect(prose.hasPrefix("Either A") && prose.hasSuffix("Next.") && !prose.contains(SpokenText.tableOmitted))
        // Streaming: the header is held until the delimiter row decides.
        var f = SpokenText.Incremental()
        var out = f.feed("Name | Size\n")
        #expect(out.isEmpty)
        out += f.feed("---|---\nlogs | 2 GB\n\nThat is all.\n")
        #expect(out == [SpokenText.tableOmitted, "That is all."])
        var g = SpokenText.Incremental()
        #expect(g.feed("Pick A | B\n").isEmpty)
        let late = g.feed("Then go.\n")
        #expect(late.count == 2 && late[0].hasPrefix("Pick A") && late[1] == "Then go.")
        // A reply that ends on a pipe line with no newline after it is still said.
        #expect(SpokenText.forSpeech("Either A | or B.").hasPrefix("Either A"))
        var h = SpokenText.Incremental()
        #expect(h.feed("Either A | or B.").isEmpty)
        #expect(h.finish().first?.hasPrefix("Either A") == true)
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

/// The end of a sound, and what Google's errors become.
@Suite struct VoicePlaybackTests {
    @Test func aChunkKnowsItsFramesAndFadesToSilenceAtTheEnd() {
        // 24,000 bytes of int16 mono are 12,000 frames; the player's buffer must agree.
        var samples = [Int16](repeating: 10_000, count: 12_000)
        samples[0] = -20_000
        let chunk = samples.withUnsafeBytes { AudioChunk(sampleRate: 24000, channels: 1, isFloat32: false, data: Data($0)) }
        #expect(chunk.frameCount == 12_000 && chunk.pcmBuffer()?.frameLength == 12_000)
        let faded = chunk.fadedOut(seconds: 0.02)   // 480 frames
        #expect(faded.frameCount == 12_000 && faded.data.count == chunk.data.count)
        let out = faded.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(out[0] == -20_000 && out[11_000] == 10_000)
        #expect(out[11_999] == 0 || abs(Int(out[11_999])) <= 21)
        #expect(out[11_520] == 10_000 && out[11_760] < 10_000 && out[11_760] > 0)
        // Floats, stereo, the same ramp; a chunk shorter than the fade is left alone.
        let floats: [Float] = [1, 1, 1, 1, 1, 1, 1, 1]
        let f = floats.withUnsafeBytes { AudioChunk(sampleRate: 1000, channels: 2, isFloat32: true, data: Data($0)) }
        let ff = f.fadedOut(seconds: 0.004).data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(ff[0] == 1 && ff[6] == 0.25 && ff[7] == 0.25)
        #expect(f.fadedOut(seconds: 0.001).data == f.data)
    }

    @Test func googlesErrorsBecomeOneSentenceWithTheRetryTime() {
        let quota = GeminiLive.Trouble.plain("You exceeded your current quota, please check your plan and billing details. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 3, model: gemini-3.8-flash-tts. Please retry in 4.08s.")
        #expect(quota.headline == "Google's free tier allows only a few voice previews a minute. Try again in 5 seconds." && quota.retryAfter == 5)
        #expect(GeminiLive.Trouble.plain("API key not valid. Please pass a valid API key.").headline == "Google did not accept this key.")
        #expect(GeminiLive.Trouble.plain("The Internet connection appears to be offline.").headline == "Google could not be reached. Check the connection.")
        #expect(GeminiLive.Trouble.plain("something else", what: "live sessions").headline == "Google answered with an error.")
        #expect(GeminiLive.Trouble.plain("RESOURCE_EXHAUSTED", what: "live sessions").headline == "Google's free tier allows only a few live sessions a minute. Try again in a minute.")
        #expect(quota.raw.hasPrefix("You exceeded"))
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
