import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// One request with its retries: backoff with jitter on 429, 502, 503, 504, a timeout and a network
// error, honouring `Retry-After`, at most `maxRetries` times, as the TypeScript SDK does. Every call of the
// client may run twice: reads, and an upload's creation with its Idempotency-Key. The upload URL takes
// one PUT and never goes through here.

/// Sends a request and answers its response; the SDK's calls go through it, so an app can log them or
/// a test can answer them. The bytes of an upload do not: they need a session of their own.
public protocol VidexoTransport: Sendable {
    /// Throws when no answer came, and stops when the calling task is cancelled.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The default transport.
public struct URLSessionTransport: VidexoTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let running = RunningTask()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                running.set(task)
                task.resume()
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// A URLSession task a cancellation handler may reach before it exists.
private final class RunningTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// Response headers with lowercase names.
typealias HTTPHeaders = [String: String]

func lowercasedHeaders(_ response: HTTPURLResponse) -> HTTPHeaders {
    var headers = HTTPHeaders()
    for (name, value) in response.allHeaderFields {
        if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
    }
    return headers
}

/// What tests replace.
struct SDKEnvironment: Sendable {
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
    var now: @Sendable () -> Date = { Date() }
    var uuid: @Sendable () -> String = { UUID().uuidString }
}

struct HTTPAnswer: Sendable {
    let status: Int
    let headers: HTTPHeaders
    let body: Data

    var isOK: Bool { (200..<300).contains(status) }
}

/// A Retry-After longer than this is not waited for: the answer is returned as it is.
let maxRetryAfterSeconds = 60
private let retryStatuses: Set<Int> = [429, 502, 503, 504]

/// The wait before retry `attempt` (0-based) without a Retry-After: 0.5 s doubling to 8 s, with jitter.
func backoffSeconds(attempt: Int, random: Double) -> TimeInterval {
    min(8, 0.5 * pow(2, Double(attempt))) * (0.5 + random / 2)
}

private struct AttemptTimedOut: Error {}

/// One attempt, within `timeout` when one is set.
private func attempt(
    _ transport: any VidexoTransport,
    _ request: URLRequest,
    timeout: TimeInterval?
) async throws -> (Data, HTTPURLResponse) {
    guard let timeout else { return try await transport.send(request) }
    return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse)?.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await transport.send(request) }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            return nil
        }
        guard let answer = try await group.next(), let answer else { throw AttemptTimedOut() }
        return answer
    }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let error = error as? URLError { return error.code == .cancelled }
    return false
}

func sendWithRetries(
    _ transport: any VidexoTransport,
    _ original: URLRequest,
    maxRetries: Int,
    timeout: TimeInterval?,
    environment: SDKEnvironment,
    redact: (String) -> String
) async throws -> HTTPAnswer {
    var request = original
    // The session's own idle timer must not fire before this attempt's.
    if let timeout { request.timeoutInterval = max(timeout, 1) } else { request.timeoutInterval = 7 * 24 * 3600 }
    let name = "\(original.httpMethod ?? "GET") \(original.url?.path ?? "")"
    var attemptNumber = 0
    while true {
        let last = attemptNumber >= maxRetries
        if Task.isCancelled { throw sdkError(.aborted, "\(name) was aborted.") }
        let failure: VidexoError
        do {
            let (data, response) = try await attempt(transport, request, timeout: timeout)
            let headers = lowercasedHeaders(response)
            let retryAfter = retryAfterSeconds(headers["retry-after"], now: environment.now())
            if !last, retryStatuses.contains(response.statusCode), (retryAfter ?? 0) <= maxRetryAfterSeconds {
                try await environment.sleep(retryAfter.map(TimeInterval.init) ?? backoffSeconds(attempt: attemptNumber, random: environment.random()))
                attemptNumber += 1
                continue
            }
            return HTTPAnswer(status: response.statusCode, headers: headers, body: data)
        } catch is AttemptTimedOut {
            failure = sdkError(.timeout, "\(name) got no answer within \(Int(timeout ?? 0)) s.")
        } catch {
            if isCancellation(error) || Task.isCancelled { throw sdkError(.aborted, "\(name) was aborted.") }
            if let error = error as? VidexoError { throw error }
            if (error as? URLError)?.code == .timedOut {
                failure = sdkError(.timeout, "\(name) got no answer in time.")
            } else {
                failure = sdkError(.networkError, "\(name) failed: \(redact(error.localizedDescription))")
            }
        }
        if last { throw failure }
        do {
            try await environment.sleep(backoffSeconds(attempt: attemptNumber, random: environment.random()))
        } catch {
            throw sdkError(.aborted, "\(name) was aborted.")
        }
        attemptNumber += 1
    }
}
