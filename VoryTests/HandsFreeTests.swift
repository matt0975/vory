import Foundation
import Testing
@testable import VoryCore

/// The hands-free loop's rules: listen, send, speak, listen again, and what cards, mute,
/// pause and barge-in do to it.
@Suite struct HandsFreeLoopTests {
    @Test func oneTurnGoesRoundTheLoop() {
        var s = HandsFreeState()
        #expect(s.handle(.start) == [.openMic])
        #expect(s.phase == .listening)
        #expect(s.handle(.speechStarted) == [.captureStart])
        #expect(s.hearing && s.capturing)
        #expect(s.handle(.speechEnded) == [.captureStop])
        #expect(s.phase == .transcribing && !s.hearing)
        #expect(s.handle(.transcript("  What's filling the disk?  ")) == [.send("What's filling the disk?")])
        #expect(s.phase == .thinking && s.caption == "What's filling the disk?" && s.sent == 1)
        #expect(s.handle(.sent).isEmpty && s.turnRunning)
        #expect(s.handle(.replyDelta("I'll look ")) == [.beginReplySpeech, .feedReply("I'll look ")])
        #expect(s.handle(.replyDelta("at /var/log.")) == [.feedReply("at /var/log.")])
        #expect(s.phase == .thinking)
        #expect(s.handle(.audioStarted).isEmpty && s.phase == .speaking)
        #expect(s.handle(.replyCompleted("I'll look at /var/log.")) == [.finishReplySpeech])
        // The turn ends on the gateway before the voice has finished: the loop waits for the voice.
        #expect(s.handle(.turnEnded(error: nil)).isEmpty && s.phase == .speaking)
        #expect(s.handle(.audioFinished).isEmpty)
        #expect(s.phase == .listening && !s.replyPending)
    }

    @Test func nothingHeardAndAFailedTranscriptGoBackToListening() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded)
        #expect(s.handle(.transcript("")).isEmpty && s.phase == .listening && s.note == "Nothing heard")
        _ = s.handle(.speechStarted)
        #expect(s.note == nil)
        _ = s.handle(.speechEnded)
        #expect(s.handle(.transcriptFailed("No STT provider")).isEmpty && s.phase == .listening && s.note == "No STT provider")
    }

    @Test func aReplyThatCameWholeIsSpokenInOneGoAndATurnWithNothingToSayListensAgain() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("hi")); _ = s.handle(.sent)
        #expect(s.handle(.replyCompleted("Hello.")) == [.speakWhole("Hello.")])
        #expect(s.replyPending)
        _ = s.handle(.turnEnded(error: nil))
        #expect(s.phase == .thinking)
        _ = s.handle(.audioStarted); _ = s.handle(.audioFinished)
        #expect(s.phase == .listening)

        var t = HandsFreeState()
        _ = t.handle(.start); _ = t.handle(.speechStarted); _ = t.handle(.speechEnded); _ = t.handle(.transcript("hi")); _ = t.handle(.sent)
        #expect(t.handle(.turnEnded(error: "The model is down")).isEmpty)
        #expect(t.phase == .listening && t.note == "The model is down")
    }

    @Test func aCardStopsTheLoopAndSaysSoOnceThenTheScreenAnswers() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("clean it up")); _ = s.handle(.sent)
        #expect(s.handle(.cardArrived(summary: "Delete 34 rotated log files")) == [.announce("Approval needed: Delete 34 rotated log files. Approve on screen.")])
        #expect(s.phase == .needsApproval && s.cardsPending)
        // No speech is taken while it waits.
        #expect(s.handle(.speechStarted).isEmpty && !s.capturing)
        // The reply that follows the approval is still spoken.
        #expect(s.handle(.replyDelta("Done.")) == [.beginReplySpeech, .feedReply("Done.")])
        #expect(s.handle(.cardsCleared).isEmpty && s.phase == .speaking)
        _ = s.handle(.replyCompleted("Done.")); _ = s.handle(.turnEnded(error: nil)); _ = s.handle(.audioFinished)
        #expect(s.phase == .listening)

        // A card while the person is mid-sentence drops the recording.
        var t = HandsFreeState()
        _ = t.handle(.start); _ = t.handle(.speechStarted)
        #expect(t.handle(.cardArrived(summary: "sudo")) == [.captureCancel, .announce("Approval needed: sudo. Approve on screen.")])
        #expect(t.handle(.cardsCleared).isEmpty && t.phase == .listening)
    }

    @Test func aCardDuringAStreamingReplyClosesItsSpeechAndTheWordsAfterTheAnswerStartAfresh() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("clean it up")); _ = s.handle(.sent)
        _ = s.handle(.replyDelta("I'll clear the old logs. ")); _ = s.handle(.audioStarted)
        #expect(s.phase == .speaking)
        // The card comes while the reply streams: the reply's speech is closed where it is
        // (the rest of the words come only after the answer), then the card is announced.
        #expect(s.handle(.cardArrived(summary: "Delete 34 rotated log files")) == [.finishReplySpeech, .announce("Approval needed: Delete 34 rotated log files. Approve on screen.")])
        #expect(s.phase == .needsApproval && s.replyCut && !s.replySpoken)
        // The spoken part drains; the loop stays on the card.
        #expect(s.handle(.audioFinished).isEmpty && s.phase == .needsApproval && !s.replyPending)
        // Answered on the screen, the bot goes on: the new words are a fresh reply.
        #expect(s.handle(.cardsCleared).isEmpty && s.phase == .thinking)
        #expect(s.handle(.replyDelta("Done, 4.2 GB freed.")) == [.beginReplySpeech, .feedReply("Done, 4.2 GB freed.")])
        #expect(!s.replyCut)
        #expect(s.handle(.replyCompleted("I'll clear the old logs. Done, 4.2 GB freed.")) == [.finishReplySpeech])
        _ = s.handle(.turnEnded(error: nil)); _ = s.handle(.audioFinished)
        #expect(s.phase == .listening)

        // The same, but the turn completes with no words after the answer: the whole reply is
        // not said a second time.
        var t = HandsFreeState()
        _ = t.handle(.start); _ = t.handle(.speechStarted); _ = t.handle(.speechEnded); _ = t.handle(.transcript("clean it up")); _ = t.handle(.sent)
        _ = t.handle(.replyDelta("Clearing them now.")); _ = t.handle(.audioStarted)
        _ = t.handle(.cardArrived(summary: "rm")); _ = t.handle(.audioFinished); _ = t.handle(.cardsCleared)
        #expect(t.handle(.replyCompleted("Clearing them now.")).isEmpty && !t.replyCut)
        #expect(t.handle(.turnEnded(error: nil)).isEmpty && t.phase == .listening)

        // A turn that ends while a reply is still open (no completion came) closes the reply,
        // so its speech ends instead of waiting on words that never come.
        var u = HandsFreeState()
        _ = u.handle(.start); _ = u.handle(.speechStarted); _ = u.handle(.speechEnded); _ = u.handle(.transcript("hi")); _ = u.handle(.sent)
        _ = u.handle(.replyDelta("Half a")); _ = u.handle(.audioStarted)
        #expect(u.handle(.turnEnded(error: nil)) == [.finishReplySpeech] && u.phase == .speaking)
        #expect(u.handle(.audioFinished).isEmpty && u.phase == .listening)
    }

    @Test func bargeInStopsTheVoiceAndListensMuteClosesTheMic() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("hi")); _ = s.handle(.sent)
        _ = s.handle(.replyDelta("A long reply")); _ = s.handle(.audioStarted)
        #expect(s.handle(.bargeIn) == [.stopSpeaking, .captureStart])
        #expect(s.phase == .listening && s.hearing && s.capturing && !s.replyPending)
        // The rest of that reply is not spoken.
        #expect(s.handle(.replyDelta(" goes on")) .isEmpty)
        _ = s.handle(.speechEnded)
        #expect(s.phase == .transcribing)

        var m = HandsFreeState()
        _ = m.handle(.start); _ = m.handle(.speechStarted)
        #expect(m.handle(.mute) == [.captureCancel, .closeMic])
        #expect(m.isMuted && !m.capturing && m.phase == .listening && m.title == "Muted")
        #expect(m.handle(.speechStarted).isEmpty)
        #expect(m.handle(.unmute) == [.openMic])
        // Muted while the bot speaks: no barge-in.
        var b = HandsFreeState()
        _ = b.handle(.start); _ = b.handle(.mute); _ = b.handle(.speechStarted)
        b.phase = .speaking
        #expect(b.handle(.bargeIn).isEmpty && b.phase == .speaking)
    }

    @Test func pauseAndInterruptionsStopEverythingAndResumeWhereTheChatIs() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted)
        #expect(s.handle(.pause) == [.captureCancel, .stopSpeaking, .closeMic])
        #expect(s.phase == .paused && s.pausedBy == .person)
        #expect(s.handle(.resume) == [.openMic] && s.phase == .listening)

        // Paused mid-turn: resumes to thinking; a card waiting: to needs approval.
        _ = s.handle(.speechStarted); _ = s.handle(.speechEnded); _ = s.handle(.transcript("hi")); _ = s.handle(.sent)
        _ = s.handle(.pause)
        #expect(s.handle(.resume) == [.openMic] && s.phase == .thinking)
        _ = s.handle(.cardArrived(summary: "x")); _ = s.handle(.pause)
        _ = s.handle(.resume)
        #expect(s.phase == .needsApproval)

        var i = HandsFreeState()
        _ = i.handle(.start)
        #expect(i.handle(.interruptionBegan) == [.stopSpeaking, .closeMic] && i.pausedBy == .interruption)
        #expect(i.handle(.interruptionEnded(resume: false)).isEmpty && i.phase == .paused && i.note?.contains("interrupted") == true)
        // The person taps Resume.
        #expect(i.handle(.resume) == [.openMic] && i.phase == .listening)
        var j = HandsFreeState()
        _ = j.handle(.start); _ = j.handle(.interruptionBegan)
        #expect(j.handle(.interruptionEnded(resume: true)) == [.openMic] && j.phase == .listening)
        // A pause by the person is not undone by the phone's interruption ending.
        var k = HandsFreeState()
        _ = k.handle(.start); _ = k.handle(.pause)
        #expect(k.handle(.interruptionEnded(resume: true)).isEmpty && k.phase == .paused)
        // Muted and paused: resume opens nothing.
        var m = HandsFreeState()
        _ = m.handle(.start); _ = m.handle(.mute); _ = m.handle(.pause)
        #expect(m.handle(.resume).isEmpty && m.phase == .listening && m.isMuted)
    }

    @Test func endIsFinalAndStartKnowsWhereTheChatAlreadyIs() {
        var s = HandsFreeState()
        _ = s.handle(.start); _ = s.handle(.speechStarted)
        #expect(s.handle(.end) == [.captureCancel, .stopSpeaking, .closeMic])
        #expect(s.phase == .ended)
        #expect(s.handle(.speechStarted).isEmpty && s.handle(.resume).isEmpty && s.phase == .ended)

        var running = HandsFreeState()
        running.turnRunning = true
        #expect(running.handle(.start) == [.openMic] && running.phase == .thinking)
        var card = HandsFreeState()
        card.cardsPending = true
        _ = card.handle(.start)
        #expect(card.phase == .needsApproval)
    }
}

/// What a spoken turn carries to the gateway.
@Suite struct VoiceTurnTests {
    @Test func theExchangeIsNewestLastWithinTheLimitAndTheParamsAreTheGatewaysNames() {
        var x = SpokenExchange()
        #expect(x.context.isEmpty)
        x.said("What's filling the disk?")
        x.heard("Rotated logs, 4.2 GB.")
        x.said("  ")
        #expect(x.context == "User: What's filling the disk?\nAssistant: Rotated logs, 4.2 GB.")
        for i in 0..<20 { x.said("line \(i)") }
        #expect(x.lines.count == SpokenExchange.keep && x.lines.last?.text == "line 19" && x.lines.first?.text == "line 12")
        var long = SpokenExchange()
        long.said(String(repeating: "a", count: 4000))
        long.heard(String(repeating: "b", count: 4000))
        #expect(long.context.count <= VoiceTurn.contextLimit && long.context.hasPrefix("Assistant: bbb"))

        var params: [String: JSONValue] = ["session_id": .string("s"), "text": .string("yes")]
        VoiceTurn(context: "User: hi", interrupted: true).apply(to: &params)
        #expect(params["surface"] == .string("voice-live") && params["voice_context"] == .string("User: hi") && params["interrupted"] == true)
        #expect(params["text"] == .string("yes"))
        var plain: [String: JSONValue] = [:]
        VoiceTurn().apply(to: &plain)
        #expect(plain == ["surface": .string("voice-live")])
    }
}

/// The spoken-text filter fed a reply in pieces, as it streams.
@Suite struct SpokenTextStreamingTests {
    @Test func piecesComeOutAsLinesAndSentencesFinishAndMatchTheWholeFilter() {
        let reply = "## Found it\n\nThe `nginx` logs are **2.1 GB**. Rotated files older than 90 days make up most of it, see [the list](https://x).\n\n```bash\nfind /var/log -delete\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nShall I run it?"
        var f = SpokenText.Incremental()
        var out: [String] = []
        // Cut at odd places: inside words, inside the fence, inside the table.
        var i = reply.startIndex
        var step = 3
        while i < reply.endIndex {
            let j = reply.index(i, offsetBy: step, limitedBy: reply.endIndex) ?? reply.endIndex
            out += f.feed(String(reply[i..<j]))
            i = j
            step = step == 3 ? 7 : 3
        }
        out += f.finish()
        #expect(out.joined(separator: " ") == SpokenText.forSpeech(reply))
        #expect(out.first == "Found it.")
        #expect(out.contains(SpokenText.codeOmitted) && out.contains(SpokenText.tableOmitted))
        #expect(out.last == "Shall I run it?")
    }

    @Test func aFinishedSentenceInALongParagraphIsReleasedEarlyButNotInsideCodeOrALink() {
        var f = SpokenText.Incremental()
        #expect(f.feed("The index is built now. The export runs in 40 seconds, ") == ["The index is built now."])
        #expect(f.feed("which is fine. Next I") == ["The export runs in 40 seconds, which is fine."])
        #expect(f.finish() == ["Next I"])

        var g = SpokenText.Incremental()
        #expect(g.feed("Run `rm -rf ./tmp. ` then check [the log. ](x) and ").isEmpty)
        #expect(g.finish() == ["Run rm -rf ./tmp.  then check the log.  and"])

        var h = SpokenText.Incremental()
        #expect(h.feed("e.g. this").isEmpty)   // too short to be a sentence end
        #expect(h.finish() == ["e.g. this"])
    }

    @Test func anUnclosedFenceIsNotedAtTheEndAndEndsSentenceKnowsItsMarks() {
        var f = SpokenText.Incremental()
        #expect(f.feed("Here:\n```python\nprint(1)") == ["Here:"])
        #expect(f.finish() == [SpokenText.codeOmitted])
        #expect(SpokenText.endsSentence("Done. ") && !SpokenText.endsSentence("Done, and") && !SpokenText.endsSentence(""))
    }
}

/// What the voice screen scrolls through.
@Suite struct VoiceTranscriptTests {
    @Test func linesGrowByIdKeepTheirPlaceAndEmptyOnesGoWhenClosed() {
        var t = VoiceTranscript()
        let person = UUID(), bot = UUID()
        t.write(person, isPerson: true, text: "What is")
        t.write(person, isPerson: true, text: "What is filling the disk?")
        t.write(bot, isPerson: false, text: "Let me")
        // A late write to the person's line lands in its place, not at the end.
        t.write(person, isPerson: true, text: "What is filling the disk?", final: true)
        #expect(t.lines.map(\.text) == ["What is filling the disk?", "Let me"])
        #expect(t.lines[0].isFinal && t.lines[0].isPerson && !t.lines[1].isFinal && !t.lines[1].isPerson)
        t.write(bot, isPerson: false, text: "Let me check.", final: true)
        #expect(t.last?.text == "Let me check." && t.last?.isFinal == true)
        let nothing = UUID()
        t.write(nothing, isPerson: true, text: " ")
        #expect(t.lines.count == 3)
        t.finish(nothing)
        #expect(t.lines.count == 2)
        t.write(UUID(), isPerson: false, text: "More")
        t.finishAll()
        #expect(t.lines.count == 3 && t.lines.allSatisfy(\.isFinal))
    }

    @Test func onlyTheLastLinesAreKept() {
        var t = VoiceTranscript()
        for i in 0..<(VoiceTranscript.keep + 5) { t.write(UUID(), isPerson: i % 2 == 0, text: "line \(i)", final: true) }
        #expect(t.lines.count == VoiceTranscript.keep && t.lines.first?.text == "line 5")
    }
}
