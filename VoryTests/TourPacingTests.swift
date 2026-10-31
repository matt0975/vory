#if os(iOS)
import Foundation
import Testing
@testable import Vory

/// Onboarding's motion and pacing (#489, Matt: Vory's motion was too big and sometimes overlapped his bubble, and on a
/// beat with more than one line they changed too fast).
@Suite @MainActor struct TourPacingTests {
    /// A line stays up for its typing, then a second, then 0.3 s a word; under Reduce Motion (no typing) the rest only.
    @Test func aLineStaysUpLongerTheLongerItIs() {
        #expect(abs(TourLines.hold(for: "Hi, I\u{2019}m Vory.", typed: false) - (1.0 + 0.3 * 3)) < 0.0001)
        #expect(abs(TourLines.hold(for: "ab c", typed: true) - (0.022 * 3 + 0.012 + 1.0 + 0.3 * 2)) < 0.0001)
        #expect(TourLines.hold(for: "Give me a backup address and I\u{2019}ll still find you away from home.", typed: true)
                > TourLines.hold(for: "Go on, tap one.", typed: true))
        for beat in TourBeat.allCases {
            for line in TourLines.lines(beat, demo: true) { #expect(TourLines.hold(for: line, typed: false) >= 1.3, "\(line)") }
        }
    }

    /// Beat 3's card moves the tour on to beat 4 once both the card has come and its hold has ended, whichever is last:
    /// the hold ending first, then the card; and wherever the answer is when the hold ends (not given, given and its turn
    /// over, given and its turn still running). No card, no move; a fresh chat leaves nothing from the one before.
    @Test func theCardMovesTheTourOnOnceWhicheverComesLast() {
        var holdFirst = TourCardMove()
        let h1 = holdFirst.holdEnded(on: .chat), h2 = holdFirst.cardUp(on: .chat)
        #expect(h1 == nil && h2 == .approval, "the hold ended before the card")
        // The answer's phases change nothing here: the card coming and the hold ending are all it waits for, so the
        // card left up, answered with its turn over, or answered with its turn still running all move it at the hold.
        for order in ["not answered", "answered, turn over", "answered, turn running"] {
            var run = TourCardMove()
            let c = run.cardUp(on: .chat), h = run.holdEnded(on: .chat)
            #expect(c == nil && h == .approval, "\(order)")
            // Once: nothing more moves it.
            let again = run.cardUp(on: .chat), againHold = run.holdEnded(on: .chat)
            #expect(run.moved && again == nil && againHold == nil, "\(order), again")
        }
        var noCard = TourCardMove()
        let n = noCard.holdEnded(on: .chat)
        #expect(n == nil && !noCard.moved, "no card")
        // A fresh chat before the move: neither the old chat's card nor its hold carries over.
        var fresh = TourCardMove()
        _ = fresh.cardUp(on: .chat); fresh.freshChat()
        let f = fresh.holdEnded(on: .chat)
        #expect(f == nil, "a card from the chat before")
        var freshHold = TourCardMove()
        _ = freshHold.holdEnded(on: .chat); freshHold.freshChat()
        let fh = freshHold.cardUp(on: .chat)
        #expect(fh == nil, "a hold from the chat before")
        // Not on beat 3: no move.
        var elsewhere = TourCardMove()
        let e1 = elsewhere.cardUp(on: .approval), e2 = elsewhere.holdEnded(on: .approval)
        #expect(e1 == nil && e2 == nil, "beat 4")
    }

    /// On a move to or from the bots beat each bubble speaks for its own beat: the one above him for the bots beat, the
    /// one under him for the beat it hangs under him on. Elsewhere neither: the beat in front's line, as before.
    @Test func eachBubbleSpeaksForItsOwnBeatOnAMoveToTheBots() {
        for compact in [false, true] {
            let fromHello = VoryTourLayer.speakers(0.4, compact: compact)
            #expect(fromHello.under == .hello && fromHello.hung == .bots, "hello to bots")
            let toChat = VoryTourLayer.speakers(1.6, compact: compact)
            #expect(toChat.under == .chat && toChat.hung == .bots, "bots to chat")
            let atBots = VoryTourLayer.speakers(1, compact: compact)
            #expect(atBots.hung == .bots, "on the bots beat")
            let onChat = VoryTourLayer.speakers(2.5, compact: compact)
            #expect(onChat.under == nil && onChat.hung == nil, "chat to approval")
        }
    }

    /// Where his bubble hangs under him, it starts clear of his face at the bottom of his float, on every beat and at
    /// both of his sizes, by the gap; under Reduce Motion there's no float and the room is larger still.
    @Test func hisBubbleStartsClearOfHimAtTheBottomOfHisFloat() {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667), CGSize(width: 1032, height: 1376)] {
            for beat in TourBeat.allCases {
                for compact in [false, true] {
                    let p = VoryTourLayer.place(beat, compact: compact)
                    guard p.bubbleTop == nil else { continue }
                    let faceBottom = VoryTourLayer.faceY(p, in: size) + p.size / 2 + VoryTourLayer.bob
                    #expect(VoryTourLayer.bubbleTop(p, in: size) - faceBottom >= VoryTourLayer.bubbleGap, "\(beat) compact \(compact) \(size)")
                }
            }
        }
    }

    /// Between the pages his bubble never passes over him: the one under him keeps the gap under his face all the way,
    /// and on a move between it and the one the bots beat hangs above him the two cross-fade, neither showing halfway.
    @Test func hisBubblesCrossFadeRatherThanPassOverHim() {
        let last = CGFloat(TourBeat.allCases.count - 1)
        for size in [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667), CGSize(width: 1032, height: 1376)] {
            for compact in [false, true] {
                for step in 0...Int(last * 100) {
                    let p = CGFloat(step) / 100
                    let s = VoryTourLayer.spot(p, in: size, compact: compact)
                    #expect(s.under - (s.faceY + s.size / 2 + VoryTourLayer.bob) >= VoryTourLayer.bubbleGap - 0.001, "\(p) \(compact) \(size)")
                    #expect(s.underShows + s.hungShows <= 1.001, "\(p) \(compact) \(size)")
                }
                for (i, beat) in TourBeat.allCases.enumerated() {
                    let hangs = VoryTourLayer.place(beat, compact: compact).bubbleTop != nil
                    let rest = VoryTourLayer.spot(CGFloat(i), in: size, compact: compact)
                    #expect(rest.underShows == (hangs ? 0 : 1) && rest.hungShows == (hangs ? 1 : 0), "\(beat) \(compact)")
                    guard i + 1 < TourBeat.allCases.count,
                          hangs != (VoryTourLayer.place(TourBeat.allCases[i + 1], compact: compact).bubbleTop != nil) else { continue }
                    let halfway = VoryTourLayer.spot(CGFloat(i) + 0.5, in: size, compact: compact)
                    #expect(halfway.underShows == 0 && halfway.hungShows == 0, "\(beat) to the next, halfway")
                }
            }
        }
    }
}
#endif
