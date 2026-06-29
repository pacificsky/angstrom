import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#endif

/// Installs a clean handler for a Unix signal (e.g. `SIGINT` from Ctrl-C) using
/// a `DispatchSource`, so the async handler runs instead of the default
/// terminate-the-process behavior.
final class SignalHandler: @unchecked Sendable {
    private let source: any DispatchSourceSignal

    private init(source: any DispatchSourceSignal) { self.source = source }

    /// Ignore the default disposition and observe `signal` via a dispatch source
    /// on a background queue (the main queue isn't reliably serviced under an
    /// async `@main`). The handler is invoked once per delivery.
    static func install(_ signal: Int32, handler: @escaping @Sendable () async -> Void) -> SignalHandler {
        #if canImport(Darwin)
        Darwin.signal(signal, SIG_IGN)
        #endif
        let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
        source.setEventHandler { Task { await handler() } }
        source.resume()
        return SignalHandler(source: source)
    }

    func cancel() { source.cancel() }
}
