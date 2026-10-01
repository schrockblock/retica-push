import Testing
import Foundation
import ReTiCA
@testable import ReTiCAPushCore

/// Intercepts every request of a session built with `stubbedSession()`. Serialized because the
/// handler is process-global.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func ok(_ status: Int, _ body: String = "") -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
    { request in
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

private func signed(_ domain: PushRegistration.Domain) -> SignedRegistration {
    let me = Identity()
    return PushRegistration(publicKey: me.publicKey, pushToken: Data([1, 2, 3]), environment: .sandbox,
                            bundleID: "co.example.app", issuedAt: 1_700_000_000).signed(with: me, domain: domain)!
}

private let base = URL(string: "https://hub.example.net/push/")!

@Suite(.serialized) struct RegistrationClientTests {
    @Test func registrationClientPostsJSONToTheRegistrationsPath() async throws {
        StubURLProtocol.handler = ok(200, "{\"destination_hash\":\"00\"}")
        let client = RegistrationClient.live(session: stubbedSession())
        let request = signed(.register)
        try await client.register(request, base)
        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://hub.example.net/push/v1/registrations")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try SignedRegistration.fromJSON(try #require(StubURLProtocol.lastBody), domain: .register)
        #expect(body == request)
    }

    @Test func registrationClientUnregisterUsesDELETE() async throws {
        StubURLProtocol.handler = ok(204)
        let client = RegistrationClient.live(session: stubbedSession())
        try await client.unregister(signed(.unregister), base)
        #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://hub.example.net/push/v1/registrations")
    }

    @Test func registrationClientThrowsOnNon2xx() async {
        StubURLProtocol.handler = ok(401, "nope")
        let client = RegistrationClient.live(session: stubbedSession())
        await #expect(throws: RegistrationClient.Failure.server(status: 401, body: "nope")) {
            try await client.register(signed(.register), base)
        }
    }

    @Test func registrationClientWrapsTransportErrors() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = RegistrationClient.live(session: stubbedSession())
        await #expect(throws: RegistrationClient.Failure.transport(URLError(.notConnectedToInternet).localizedDescription)) {
            try await client.register(signed(.register), base)
        }
    }

    @Test func registrationClientTreats204AsSuccess() async throws {
        StubURLProtocol.handler = ok(204, "unexpected body")
        let client = RegistrationClient.live(session: stubbedSession())
        try await client.register(signed(.register), base)
    }
}
