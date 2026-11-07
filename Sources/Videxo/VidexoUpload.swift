import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Sending the bytes of a file to an upload's one-time URL. The URL holds no API key, so it may come from
// a client token or from your backend. It takes one PUT, within one hour: nothing here retries it, and
// after a failed PUT the next try needs a new upload.

private let defaultContentType = "application/octet-stream"

/// A response body this long is no upload answer; the rest is not kept.
private let maxAnswerBytes = 1_048_576

/// The content type of a file by its extension; `application/octet-stream` when it has no known one.
func contentTypeOf(_ file: URL) -> String {
    #if canImport(UniformTypeIdentifiers)
    return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? defaultContentType
    #else
    return defaultContentType
    #endif
}

/// The size of a file; refuses one it cannot read.
func fileSize(_ file: URL) throws -> Int64 {
    guard file.isFileURL else { throw sdkError(.invalidArgument, "An upload is sent from a file URL.") }
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber
    else {
        throw sdkError(.invalidArgument, "The file to upload cannot be read: \(file.lastPathComponent).")
    }
    return size.int64Value
}

/// A file name as the API wants it: letters, digits, dots, underscores and hyphens, starting with a
/// letter or digit, at most 105 characters.
func plainFilename(_ name: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
    let startsAName: (Character) -> Bool = { $0.isLetter || $0.isNumber }
    let cleaned = name.map { allowed.contains($0) ? $0 : "-" }.suffix(105).drop { !startsAName($0) }
    return cleaned.isEmpty ? "upload.bin" : String(cleaned)
}

/// The answer of an upload URL, or why there is none.
func completedUpload(status: Int?, headers: HTTPHeaders, body: Data, failure: Error?) -> Result<CompletedUpload, VidexoError> {
    if let failure {
        if isCancellation(failure) { return .failure(sdkError(.aborted, "The upload was aborted.")) }
        if (failure as? URLError)?.code == .timedOut { return .failure(sdkError(.timeout, "The upload did not finish in time.")) }
        // Only the fixed sentence: a URL error's details hold the upload URL.
        return .failure(sdkError(.networkError, "The upload failed: the connection was lost. Create a new upload to try again."))
    }
    guard let status else { return .failure(sdkError(.networkError, "The upload failed: no answer came.")) }
    guard (200..<300).contains(status) else { return .failure(errorFromResponse(status: status, headers: headers, body: body)) }
    guard let completed = try? apiDecoder().decode(CompletedUpload.self, from: body) else {
        return .failure(sdkError(.invalidResponse, "The upload URL answered without the completed upload.", status: status, body: body))
    }
    return .success(completed)
}

/// The delegate of a session that sends files: the answer of each task, its progress and its end.
final class UploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Int: Data] = [:]
    private let onProgress: @Sendable (URLSessionTask, Int64, Int64) -> Void
    private let onComplete: @Sendable (URLSessionTask, Result<CompletedUpload, VidexoError>) -> Void

    init(
        onProgress: @escaping @Sendable (URLSessionTask, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (URLSessionTask, Result<CompletedUpload, VidexoError>) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(task, totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        var answer = answers[dataTask.taskIdentifier] ?? Data()
        if answer.count < maxAnswerBytes { answer.append(data.prefix(maxAnswerBytes - answer.count)) }
        answers[dataTask.taskIdentifier] = answer
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = answers.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        let response = task.response as? HTTPURLResponse
        let headers = response.map(lowercasedHeaders) ?? [:]
        onComplete(task, completedUpload(status: response?.statusCode, headers: headers, body: body, failure: error))
    }

    #if !canImport(FoundationNetworking)
    var onFinishedEvents: (@Sendable () -> Void)?

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onFinishedEvents?()
    }
    #endif
}

/// One upload under way: its result, and pause, resume and cancel.
public final class UploadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CompletedUpload, VidexoError>?
    private var waiters: [CheckedContinuation<CompletedUpload, Error>] = []
    private var task: URLSessionTask?

    init() {}

    fileprivate func started(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    fileprivate func finish(_ result: Result<CompletedUpload, VidexoError>) {
        lock.lock()
        let waiting = waiters
        waiters = []
        self.result = result
        task = nil
        lock.unlock()
        for waiter in waiting { waiter.resume(with: result.mapError { $0 as Error }) }
    }

    /// The completed upload, once every byte arrived.
    public var value: CompletedUpload {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result.mapError { $0 as Error })
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    /// Stops sending and keeps the connection. The URL allows one PUT: when the connection ends while
    /// paused, the upload fails and the next try needs a new upload.
    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        task?.suspend()
    }

    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        task?.resume()
    }

    /// Ends the upload, with `aborted` as its result. The URL is used up once bytes have been sent.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
    }
}

/// Sends a file to an upload's one-time URL, from a client token's upload or from your backend, while
/// the app runs. For an upload that goes on when the app is suspended, see `BackgroundUploader`.
///
/// ```swift
/// let completed = try await VidexoUpload().send(file: file, to: uploadURL) { progress in
///     show(progress.fraction)
/// }
/// ```
public struct VidexoUpload: Sendable {
    public init() {}

    /// Starts the upload and answers its handle.
    /// - Parameters:
    ///   - contentType: The type the upload was created with; by the file's extension when nil.
    ///   - timeout: Seconds the whole upload may take; the URL's own hour when nil.
    ///   - onProgress: Told when the system reports progress, which may be never for a small or fast
    ///     upload. An upload that succeeds always gets one with `loaded` equal to `total`, before its
    ///     result; one that fails does not.
    public func start(
        file: URL,
        to uploadURL: URL,
        contentType: String? = nil,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) throws -> UploadHandle {
        let total = try fileSize(file)
        let handle = UploadHandle()
        let delegate = UploadDelegate(
            onProgress: { _, sent, _ in onProgress?(UploadProgress(loaded: sent, total: total)) },
            onComplete: { _, result in
                // A small file can end with no progress told at all, and the caller's bar should reach its end.
                if case .success = result { onProgress?(UploadProgress(loaded: total, total: total)) }
                handle.finish(result)
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout ?? uploadURLLifetime
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.uploadTask(with: putRequest(uploadURL, contentType: contentType ?? contentTypeOf(file)), fromFile: file)
        handle.started(task)
        task.resume()
        // The session lets go of its delegate when its one task has ended.
        session.finishTasksAndInvalidate()
        return handle
    }

    /// Sends the file and answers the completed upload. It is never retried. Cancelling the calling
    /// task ends the upload.
    public func send(
        file: URL,
        to uploadURL: URL,
        contentType: String? = nil,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> CompletedUpload {
        let handle = try start(file: file, to: uploadURL, contentType: contentType, timeout: timeout, onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await handle.value
        } onCancel: {
            handle.cancel()
        }
    }
}

/// The upload URL must be fully sent within one hour.
let uploadURLLifetime: TimeInterval = 3600

func putRequest(_ uploadURL: URL, contentType: String) -> URLRequest {
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "PUT"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    return request
}
