import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession's delegate streaming API is available on both macOS and Linux.
/// A session owns its delegate until completion; cancellation breaks that cycle.
final class HTTPResponseStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let lock = NSLock()
    private var session: URLSession?
    private var finished = false

    init(request: URLRequest, configuration: URLSessionConfiguration) {
        (events, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
        super.init()
        continuation.onTermination = { [weak self] _ in self?.cancel() }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func cancel() { finish(CancellationError()) }

    private func finish(_ error: Error?) {
        let active: URLSession? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let active = session
            session = nil
            return active
        }
        guard let active else { return }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
        active.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(EndpointSessionError.invalidResponse)
            return
        }
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }
}

/// Keep incomplete UTF-8 and SSE lines intact across arbitrary network chunks.
struct SSELineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[..<end], as: UTF8.self))
            pending.removeSubrange(...end)
        }
        return lines
    }

    mutating func finish() -> [String] {
        defer { pending.removeAll() }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}
