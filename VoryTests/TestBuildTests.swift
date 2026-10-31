import StoreKit
import Testing
@testable import Vory

/// What only a test build offers (Settings › Troubleshooting's Replay the welcome tour, #487, and Screen layout, #516):
/// TestFlight's (the App Store's sandbox), Xcode's or a Debug build; never the App Store's build, nor when the App Store
/// can't say which this is. Every row reads the one flag.
@Suite struct TestBuildTests {
    @Test func onlyATestBuildIsOne() {
        #expect(TestBuild.allowed(environment: .sandbox, debug: false), "TestFlight")
        #expect(TestBuild.allowed(environment: .xcode, debug: false), "installed by Xcode")
        #expect(!TestBuild.allowed(environment: .production, debug: false), "the App Store")
        #expect(!TestBuild.allowed(environment: nil, debug: false), "the App Store couldn't say")
        #expect(TestBuild.allowed(environment: .production, debug: true), "a Debug build")
        #expect(TestBuild.allowed(environment: nil, debug: true), "a Debug build")
    }

    /// On the main actor: TroubleshootingView is a View, so its statics are the main actor's.
    @Test @MainActor func troubleshootingsTestBuildRowsAllReadTheOneFlag() {
        #expect(TroubleshootingView.testBuildRows(testBuild: false).isEmpty, "no row on the App Store's build")
        #expect(TroubleshootingView.testBuildRows(testBuild: true) == [.replayTour, .screenLayout], "both rows on a test build")
        for env: AppStore.Environment? in [.production, .sandbox, .xcode, nil] {
            let flag = TestBuild.allowed(environment: env, debug: false)
            #expect(TroubleshootingView.testBuildRows(testBuild: flag).contains(.screenLayout) == flag)
        }
    }

    // MARK: Either signal, asked until yes (#532)

    private struct Down: Error {}
    private final class Count { var n = 0 }
    private typealias Answer = (AppStore.Environment, verified: Bool)
    private func check(_ answer: Answer?, _ receipt: String?) async -> TestBuild.Check {
        await TestBuild.check(debug: false, transaction: {
            guard let answer else { throw NSError(domain: "StoreKit", code: 7) }
            return answer
        }, receiptName: receipt)
    }

    /// A test build if either signal says so: the App Store's sandbox (verified or not) or TestFlight's receipt name.
    @Test func eitherSignalMakesATestBuild() async {
        #expect(await check((.production, true), "sandboxReceipt").isTestBuild, "production with TestFlight's receipt")
        #expect(await check((.sandbox, true), "receipt").isTestBuild, "the App Store's sandbox")
        #expect(await check((.sandbox, false), nil).isTestBuild, "an unverified sandbox")
        #expect(await check(nil, "sandboxReceipt").isTestBuild, "the App Store didn't answer; TestFlight's receipt")
    }

    /// Neither signal: no, the App Store's build above all.
    @Test func neitherSignalIsNo() async {
        #expect(await !check((.production, true), "receipt").isTestBuild, "the App Store's build")
        #expect(await !check(nil, "receipt").isTestBuild, "no answer, the App Store's receipt")
        #expect(await !check(nil, nil).isTestBuild, "no answer, no receipt")
    }

    /// The line at Troubleshooting's foot: none on a confirmed App Store install; otherwise what was decided and why.
    @Test func theReasonLine() async {
        #expect(await check((.production, true), "receipt").reason == nil)
        #expect(await check((.sandbox, true), "sandboxReceipt").reason == "Build check: TestFlight (App Store: sandbox; receipt: sandbox)")
        #expect(await check((.production, true), "sandboxReceipt").reason == "Build check: TestFlight (App Store: production; receipt: sandbox)")
        #expect(await check((.xcode, false), nil).reason == "Build check: TestFlight (App Store: xcode; receipt: none)")
        #expect(await check(nil, "sandboxReceipt").reason == "Build check: TestFlight (App Store: no answer, code 7; receipt: sandbox)")
        #expect(await check(nil, "receipt").reason == "Build check: couldn't confirm (App Store: no answer, code 7; receipt: receipt)")
        #expect(await check(nil, nil).reason == "Build check: couldn't confirm (App Store: no answer, code 7; receipt: none)")
    }

    @Test @MainActor func aFirstAskThatThrowsIsAskedAgainAndTheRetryTurnsTheFlagOn() async {
        let calls = Count()
        let flag = TestBuildFlag(ask: {
            await TestBuild.check(debug: false, transaction: {
                calls.n += 1
                if calls.n == 1 { throw Down() }
                return (.sandbox, true)
            }, receiptName: nil)
        })
        await flag.refresh()
        #expect(!flag.value && flag.requests == 1, "the first ask threw, with no receipt to fall back on")
        await flag.refresh()
        #expect(flag.value && flag.requests == 2, "the retry")
    }

    @Test @MainActor func onceYesNoMoreRequests() async {
        let flag = TestBuildFlag(ask: { TestBuild.Check(store: .environment(.sandbox, verified: true), receiptName: nil) })
        await flag.refresh()
        await flag.refresh()
        await flag.refresh()
        #expect(flag.value && flag.requests == 1)
    }

    /// The App Store's answer can't change while the process runs: once it has answered, no more asking.
    @Test @MainActor func anAnswerFromTheAppStoreIsNotAskedAgain() async {
        let flag = TestBuildFlag(ask: { TestBuild.Check(store: .environment(.production, verified: true), receiptName: "receipt") })
        await flag.refresh()
        await flag.refresh()
        await flag.refresh()
        #expect(!flag.value && flag.requests == 1)
    }

    @Test @MainActor func twoFailuresThenTheSandbox() async {
        let calls = Count()
        let flag = TestBuildFlag(ask: {
            await TestBuild.check(debug: false, transaction: {
                calls.n += 1
                if calls.n <= 2 { throw Down() }
                return (.sandbox, true)
            }, receiptName: nil)
        })
        for _ in 0..<3 { await flag.refresh() }
        #expect(flag.value && flag.requests == 3)
    }

    @Test @MainActor func failuresAreAskedAgainAtMostFiveTimes() async {
        let flag = TestBuildFlag(ask: { TestBuild.Check(store: .failed(domain: "StoreKit", code: 7), receiptName: nil) })
        for _ in 0..<6 { await flag.refresh() }
        #expect(!flag.value && flag.requests == 5)
    }

    @Test @MainActor func oneRequestAtATime() async {
        let flag = TestBuildFlag(ask: {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return TestBuild.Check(store: .failed(domain: "StoreKit", code: 7), receiptName: nil)
        })
        async let a: Void = flag.refresh()
        async let b: Void = flag.refresh()
        _ = await (a, b)
        #expect(!flag.value && flag.requests == 1, "the second came while the first was out")
    }
}
