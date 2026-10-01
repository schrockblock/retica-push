import Foundation

/// HTTP client for docs/server-contract.md §1. A struct of closures, like ReTiCA's `TCPConnection`,
/// so tests and the TCA dependency can replace it. The TCA `DependencyKey` conformance lives in
/// the `ReTiCAPush` target; this target has no TCA.
public struct RegistrationClient: Sendable {
    public enum Failure: Error, Equatable {
        /// A non-2xx answer. `body` is the response body as UTF-8, truncated to 200 characters.
        case server(status: Int, body: String)
        /// No HTTP answer at all (offline, DNS, TLS).
        case transport(String)
    }

    public static let registrationsPath = "v1/registrations"
    public static let timeout: TimeInterval = 15

    public var register: @Sendable (SignedRegistration, URL) async throws -> Void
    public var unregister: @Sendable (SignedRegistration, URL) async throws -> Void

    public init(register: @escaping @Sendable (SignedRegistration, URL) async throws -> Void,
                unregister: @escaping @Sendable (SignedRegistration, URL) async throws -> Void) {
        self.register = register
        self.unregister = unregister
    }

    public static func live(session: URLSession = .shared) -> RegistrationClient {
        RegistrationClient(
            register: { signed, base in try await send(signed, to: base, method: "POST", session: session) },
            unregister: { signed, base in try await send(signed, to: base, method: "DELETE", session: session) }
        )
    }

    private static func send(_ signed: SignedRegistration, to base: URL, method: String,
                             session: URLSession) async throws {
        var request = URLRequest(url: base.appending(path: registrationsPath), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try signed.jsonData()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.server(status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}
