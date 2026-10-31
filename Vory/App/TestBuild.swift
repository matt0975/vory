import Foundation
import Observation
import StoreKit

/// A test build: a Debug build, or one installed from TestFlight (the App Store's sandbox) or by Xcode; never the App
/// Store's. The one gate for what only a test build offers, all of it on one flag (`AppModel.testBuild`):
/// Settings › Troubleshooting's Replay the welcome tour (#487) and Screen layout (#516).
enum TestBuild {
    static func allowed(environment: AppStore.Environment?, debug: Bool) -> Bool {
        debug || environment == .sandbox || environment == .xcode
    }

    /// What the App Store said: its environment (and whether its signature checked out), or that asking it failed.
    enum StoreAnswer: Equatable {
        case environment(AppStore.Environment, verified: Bool)
        case failed(domain: String, code: Int)
    }

    /// One check (#532): a test build if either signal says so, the App Store's environment (sandbox or Xcode, verified
    /// or not) or the receipt's name (TestFlight's builds carry "sandboxReceipt"). A TestFlight build whose App Store
    /// answer failed, or said production, still shows the rows; an App Store install has neither signal.
    struct Check: Equatable {
        var store: StoreAnswer
        var receiptName: String?
        var debug = false

        var isTestBuild: Bool {
            if debug || receiptName == "sandboxReceipt" { return true }
            if case .environment(let e, _) = store { return TestBuild.allowed(environment: e, debug: false) }
            return false
        }

        /// The line at the foot of Troubleshooting, in plain words: what the check decided and why. None on a confirmed App
        /// Store install (the App Store answered production and the receipt is the App Store's).
        var reason: String? {
            let store: String
            switch self.store {
            case .environment(let e, _): store = e == .sandbox ? "sandbox" : e == .xcode ? "xcode" : e == .production ? "production" : e.rawValue
            case .failed(_, let code): store = "no answer, code \(code)"
            }
            let receipt = receiptName == "sandboxReceipt" ? "sandbox" : receiptName == nil ? "none" : "receipt"
            let details = " (App Store: \(store); receipt: \(receipt))"
            if case .environment(.production, _) = self.store, receiptName == "receipt", !debug { return nil }
            if debug, !(receiptName == "sandboxReceipt"), !TestBuild.allowed(environment: environment, debug: false) {
                return "Build check: Debug build" + details
            }
            return (isTestBuild ? "Build check: TestFlight" : "Build check: couldn't confirm") + details
        }

        private var environment: AppStore.Environment? {
            if case .environment(let e, _) = store { return e }
            return nil
        }
    }

    /// The check, with the App Store's answer asked through `transaction` (the tests stand in for it).
    static func check(debug: Bool, transaction: () async throws -> (AppStore.Environment, verified: Bool), receiptName: String?) async -> Check {
        do {
            let (environment, verified) = try await transaction()
            return Check(store: .environment(environment, verified: verified), receiptName: receiptName, debug: debug)
        } catch {
            let e = error as NSError
            return Check(store: .failed(domain: e.domain, code: e.code), receiptName: receiptName, debug: debug)
        }
    }

    /// The App Store's own answer for this build.
    static func appStoreEnvironment() async throws -> (AppStore.Environment, verified: Bool) {
        switch try await AppTransaction.shared {
        case .verified(let t): return (t.environment, true)
        case .unverified(let t, _): return (t.environment, false)
        }
    }

    /// This build's check.
    static func checkHere() async -> Check {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return await check(debug: debug, transaction: appStoreEnvironment, receiptName: Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }
}

/// Whether this is a test build, asked until the answer is yes (#532): at launch, and again whenever the app comes to the
/// front or Troubleshooting appears while it's still no and the App Store hasn't answered (asking it threw). Never again
/// once yes, nor once it has answered (its answer can't change while the process runs); at most `maxAsks` asks; one
/// request at a time.
@MainActor @Observable final class TestBuildFlag {
    static let maxAsks = 5
    private(set) var value = false
    /// The last check, for Troubleshooting's reason line; nil before the first has come back.
    private(set) var last: TestBuild.Check?
    @ObservationIgnored private var asking = false
    @ObservationIgnored private let ask: () async -> TestBuild.Check
    /// How many requests went out (for the tests).
    @ObservationIgnored private(set) var requests = 0

    init(ask: @escaping () async -> TestBuild.Check = { await TestBuild.checkHere() }) { self.ask = ask }

    /// Asks again unless the answer is already yes, the App Store has answered, a request is out or the asks are used up;
    /// returns once this one (if any) is answered.
    func refresh() async {
        guard !value, !asking, requests < Self.maxAsks else { return }
        if let last, case .environment = last.store { return }
        asking = true
        requests += 1
        let check = await ask()
        asking = false
        last = check
        if check.isTestBuild { value = true }
    }
}
