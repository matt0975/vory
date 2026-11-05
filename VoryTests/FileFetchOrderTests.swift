import Foundation
import Testing
@testable import Vory
@testable import VoryCore

/// This suite's own fake transport (a static handler shared with another suite races when Swift Testing runs them side
/// by side): answers each request from `handler` and keeps the routes asked, in order.
final class FileFetchStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var routes: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.routes.append(request.url?.path ?? "")
        let (status, headers, body) = Self.handler?(request) ?? (404, ["Content-Type": "application/json"], Data(#"{"detail":"Not Found"}"#.utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A file card fetches its file (#638): the gateway's download route first, raw bytes; the picture routes only when
/// the gateway lacks that route or can't answer it; a refusal is final and said in plain words. Pictures keep their
/// own routes.
@Suite(.serialized) struct FileFetchOrderTests {
    static let download = "/api/files/download", media = "/api/media", read = "/api/files/read"
    static let pdf = Data("%PDF-1.4 a small report".utf8)

    private static func json(_ status: Int, _ body: String) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], Data(body.utf8))
    }

    /// A data URL as the picture routes send it.
    private static func dataURL(_ data: Data, _ mime: String) -> (Int, [String: String], Data) {
        Self.json(200, #"{"data_url":"data:\#(mime);base64,\#(data.base64EncodedString())"}"#)
    }

    private func makeAPI() throws -> GatewayMediaAPI {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FileFetchStubProtocol.self]
        let g = try GatewayURL.normalize("https://h.example.com")   // no path prefix: the routes read as "/api/..."
        let api = HermesAPI(gateway: g, signer: RequestSigner(authMode: .sessionToken, sessionToken: "tok"),
                            urlSession: URLSession(configuration: cfg))
        return GatewayMediaAPI(api: api, profile: "default")
    }

    /// One fetch through a store of its own (nothing cached), the routes it asked, in order.
    private func fetch(_ path: String, _ handler: @escaping @Sendable (String) -> (Int, [String: String], Data)) async throws -> (Result<Data, Error>, [String]) {
        FileFetchStubProtocol.routes = []
        FileFetchStubProtocol.handler = { handler($0.url?.path ?? "") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-fetch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MediaStore(directory: dir)
        let api = try makeAPI()
        let result: Result<Data, Error>
        do { result = .success(try Data(contentsOf: try await store.localURL(for: MediaRef(path: path), gateway: "g", api: api))) }
        catch { result = .failure(error) }
        return (result, FileFetchStubProtocol.routes)
    }

    @Test func aFileComesByTheDownloadRoute() async throws {
        let (got, routes) = try await fetch("/home/hermes/out/report.pdf") { route in
            route == Self.download ? (200, ["Content-Type": "application/pdf", "Content-Disposition": #"attachment; filename="report.pdf""#], Self.pdf)
                                   : Self.json(404, #"{"detail":"Not Found"}"#)
        }
        #expect(try got.get() == Self.pdf)
        #expect(routes == [Self.download])
    }

    /// The gateway lacks the route (Starlette's own 404, a 405, a proxy's page) or can't answer it (a sign-in the
    /// download doesn't renew: a 401, or an expired session): the picture routes, as before.
    @Test(arguments: ["no route", "wrong method", "a page", "signed out", "session expired"])
    func withoutTheRouteThePictureRoutesServe(_ answer: String) async throws {
        let (got, routes) = try await fetch("/home/hermes/out/report.pdf") { route in
            switch route {
            case Self.download:
                switch answer {
                case "no route": return Self.json(404, #"{"detail":"Not Found"}"#)
                case "wrong method": return Self.json(405, #"{"detail":"Method Not Allowed"}"#)
                case "a page": return (404, ["Content-Type": "text/html"], Data("<!doctype html><html>not here</html>".utf8))
                case "signed out": return Self.json(401, #"{"detail":"Unauthorized"}"#)
                default: return Self.json(401, #"{"error":"session_expired"}"#)
                }
            case Self.media: return Self.json(415, #"{"detail":"Unsupported media type"}"#)
            case Self.read: return Self.dataURL(Self.pdf, "application/pdf")
            default: return Self.json(404, #"{"detail":"Not Found"}"#)
            }
        }
        #expect(try got.get() == Self.pdf)
        #expect(routes == [Self.download, Self.media, Self.read])
    }

    @Test func aRefusalIsFinalAndSaidPlainly() async throws {
        let (got, routes) = try await fetch("/home/hermes/.hermes/sessions/s1.jsonl") { route in
            route == Self.download ? Self.json(403, #"{"detail":"Access denied"}"#) : Self.dataURL(Self.pdf, "application/pdf")
        }
        #expect(routes == [Self.download])
        guard case .failure(let error) = got else { Issue.record("a refused file came"); return }
        #expect(FileFetchFailure.describe(error, name: "s1.jsonl") == "This file can't be shared from the gateway")
    }

    @Test func aFileThatIsGoneIsGone() async throws {
        let (got, routes) = try await fetch("/home/hermes/out/old.pdf") { route in
            route == Self.download ? Self.json(404, #"{"detail":"File not found"}"#) : Self.dataURL(Self.pdf, "application/pdf")
        }
        #expect(routes == [Self.download])
        guard case .failure(let error) = got else { Issue.record("a gone file came"); return }
        #expect(FileFetchFailure.describe(error, name: "old.pdf") == "old.pdf is no longer on the gateway.")
    }

    /// A path from the home: the download route takes no profile, so a miss there is tried on the picture routes,
    /// which do.
    @Test func aHomePathIsTriedOnThePictureRoutes() async throws {
        let (got, routes) = try await fetch("~/out/notes.md") { route in
            switch route {
            case Self.download: return Self.json(404, #"{"detail":"File not found"}"#)
            case Self.media: return Self.json(415, #"{"detail":"Unsupported media type"}"#)
            case Self.read: return Self.dataURL(Data("# Notes".utf8), "text/markdown")
            default: return Self.json(404, #"{"detail":"Not Found"}"#)
            }
        }
        #expect(try got.get() == Data("# Notes".utf8))
        #expect(routes == [Self.download, Self.media, Self.read])
    }

    @Test func aPictureKeepsItsOwnRoute() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let (got, routes) = try await fetch("/home/hermes/out/chart.png") { route in
            route == Self.media ? Self.dataURL(png, "image/png") : Self.json(404, #"{"detail":"Not Found"}"#)
        }
        #expect(try got.get() == png)
        #expect(routes == [Self.media])
    }
}
