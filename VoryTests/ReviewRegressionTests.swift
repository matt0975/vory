import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// What the cross-review of 1.4 pinned down, kept from coming back.
@Suite struct ReviewRegressionTests {
    @Test func aHiddenPageIsNotOfferedAsALaunchTab() {
        // The Board stays in the saved layout while its plugin is off, but nothing opens on it.
        let layout = TabLayout.parse(TabLayout(tabs: [.chats, .kanban, .settings]).encoded)
        #expect(layout.visible().contains(.kanban))
        #expect(!layout.visible(hiding: [.kanban]).contains(.kanban))
        #expect(layout.visible(hiding: [.kanban]) == [.chats, .settings])
    }

    #if os(iOS)
    @MainActor @Test func theWatchGetsNoRefreshToken() throws {
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "test watch secrets", gateway: try GatewayURL.normalize("http://127.0.0.1:1"), authMode: .sessionToken)
        var secrets = GatewaySecrets(sessionToken: "session-1")
        secrets.accessToken = "access-1"
        secrets.refreshToken = "refresh-1"
        try store.upsert(conn, secrets: secrets)
        defer { store.delete(id: conn.id) }
        let sent = WatchSync.contextSecrets(store)[conn.id.uuidString]
        #expect(sent?.sessionToken == "session-1" && sent?.accessToken == "access-1")
        #expect(sent?.refreshToken == nil, "the refresh token stays on the phone")
    }
    #endif

    @Test func thePictureScanLeavesWebImagesToTheMarkdown() {
        // A gateway picture leaves the text (it is shown under the bubble); a web image stays
        // for the parser, which renders it as the block loaded on a tap.
        let text = "Look:\n![before](/home/x/.hermes/images/a.png)\n![the chart](https://example.com/c.png)\nMEDIA:/home/x/.hermes/images/b.png"
        let shown = MediaScan.textWithoutMedia(text)
        #expect(shown == "Look:\nbefore\n![the chart](https://example.com/c.png)")
        #expect(MediaScan.images(in: text).map(\.name).sorted() == ["a.png", "b.png"], "the gateway pictures, not the web one")
        let blocks = MarkdownParser.blocks(from: shown)
        #expect(blocks.contains { if case .image(let alt, let url, _) = $0 { return alt == "the chart" && url == "https://example.com/c.png" }; return false })
    }

    @Test func aPathWithPunctuationOrACarriageReturnIsStillAPicture() {
        // A path on its own line keeps its full stop and its CR (a CRLF reply): still that picture.
        #expect(MediaScan.images(in: "See:\r\n/tmp/shot.png.\r\n").map(\.name) == ["shot.png"])
        #expect(MediaScan.images(in: "/tmp/shot.png)\n").map(\.name) == ["shot.png"])
        #expect(MediaScan.textWithoutMedia("Here:\r\n/tmp/shot.png.\r\nDone.") == "Here:\nDone.")
        // Not a picture line: a path mid-sentence is prose.
        #expect(MediaScan.images(in: "See /tmp/shot.png now").isEmpty)
    }
}

/// Quick answers put back after the app died with them on: the next open of that chat restores.
@Suite(.serialized) struct QuickAnswersRestoreIntegrationTests {
    @MainActor @Test func aChatOpenedAfterAKillPutsItsReasoningBack() async throws {
        guard let env = GatewayIntegrationTests.env, env.token == "mock-token" else { return }
        let store = ConnectionStore()
        let conn = GatewayConnection(name: "e2e quick restore", gateway: try GatewayURL.normalize(env.url), authMode: .sessionToken)
        try store.upsert(conn, secrets: GatewaySecrets(sessionToken: env.token))
        defer { store.delete(id: conn.id) }
        let rt = GatewayRuntime(connection: conn, store: store)
        await rt.start()
        defer { Task { await rt.stop() } }
        let list: SessionListResponse = try await rt.api.get("/api/sessions", query: [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "1")], profile: rt.selectedProfile)
        let stored = try #require(list.sessions.first?.id)
        // What a killed voice session would have left behind.
        let key = "voice.quick.restore." + stored
        UserDefaults.standard.set(["reasoning": "high", "fast": "off"], forKey: key)
        let chat = try await rt.openChat(storedID: stored, title: nil, waitForResume: true)
        defer { rt.closeChat(chat) }
        for _ in 0..<40 where UserDefaults.standard.dictionary(forKey: key) != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(UserDefaults.standard.dictionary(forKey: key) == nil, "the restore ran and cleared what it had kept")
    }
}
