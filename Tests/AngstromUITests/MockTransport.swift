import Foundation

/// A thread-safe, in-memory backend that ``MockURLProtocol`` routes requests to.
///
/// Tests register a handler that maps each request to a status code + body,
/// and can inspect what was sent (e.g. how many sign-ins happened).
final class MockBackend: @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()

        static func json(_ object: [String: Any], status: Int = 200) -> Reply {
            Reply(status: status,
                  body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }

        static func jsonArray(_ array: [Any], status: Int = 200) -> Reply {
            Reply(status: status,
                  body: (try? JSONSerialization.data(withJSONObject: array)) ?? Data())
        }
    }

    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) -> Reply)?
    private var requests: [(path: String, method: String, body: Data?)] = []

    func onRequest(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock { self.handler = handler }
    }

    func reply(to request: URLRequest, body: Data?) -> Reply {
        let handler = lock.withLock { self.handler }
        // Compute the reply before recording, so a handler that inspects
        // `count(pathSuffix:)` sees only requests that preceded this one.
        let reply = handler?(request) ?? Reply(status: 500)
        lock.withLock { requests.append((request.url?.path ?? "", request.httpMethod ?? "", body)) }
        return reply
    }

    /// Number of recorded requests whose path ends with `suffix`
    /// (paths are prefixed with `/api/customer-app`).
    func count(pathSuffix suffix: String) -> Int {
        lock.withLock { requests.filter { $0.path.hasSuffix(suffix) }.count }
    }

    /// The body of the last request whose path ends with `suffix`.
    func body(pathSuffix suffix: String) -> Data? {
        lock.withLock { requests.last { $0.path.hasSuffix(suffix) }?.body }
    }

    /// The HTTP method of the last request whose path ends with `suffix`.
    func method(pathSuffix suffix: String) -> String? {
        lock.withLock { requests.last { $0.path.hasSuffix(suffix) }?.method }
    }

    var recordedPaths: [String] { lock.withLock { requests.map(\.path) } }
}

/// A `URLProtocol` that serves responses from a ``MockBackend``, so the client
/// can be exercised end-to-end without real network access.
///
/// Each `URLSession` is tagged with a unique `X-Mock-Backend` header (via
/// `httpAdditionalHeaders`) that routes its requests to the right backend, so
/// concurrent sessions never cross-talk through shared global state.
final class MockURLProtocol: URLProtocol {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: MockBackend] = [:]
    private static let headerKey = "X-Mock-Backend"

    private static func register(_ backend: MockBackend) -> String {
        let id = UUID().uuidString
        registryLock.withLock { registry[id] = backend }
        return id
    }

    private static func backend(for request: URLRequest) -> MockBackend? {
        guard let id = request.value(forHTTPHeaderField: headerKey) else { return nil }
        return registryLock.withLock { registry[id] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let backend = Self.backend(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let reply = backend.reply(to: request, body: Self.readBody(request))
        guard let http = HTTPURLResponse(url: url, statusCode: reply.status,
                                         httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands custom protocols the body as a stream, not `httpBody`.
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    /// A `URLSession` whose requests route to `backend`.
    static func session(backend: MockBackend) -> URLSession {
        let id = register(backend)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [headerKey: id]
        return URLSession(configuration: config)
    }
}

/// A mutable, thread-safe clock for driving token-expiry decisions in tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(by interval: TimeInterval) { lock.withLock { current.addTimeInterval(interval) } }
    func set(_ date: Date) { lock.withLock { current = date } }
}
