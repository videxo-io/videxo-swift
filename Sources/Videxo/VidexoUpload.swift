import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Sending the bytes of a file to an upload's URL. The URL holds no API key, so it may come from a client
// token or from your backend. A single upload takes one PUT, within one hour: nothing here retries it,
// and after a failed PUT the next try needs a new upload. A multipart upload (Multipart.swift) sends its
// parts again on their own and resumes.

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
func completedUpload(_ answer: TaskAnswer) -> Result<CompletedUpload, VidexoError> {
    let (status, headers, body) = (answer.status, answer.headers, answer.body)
    if let failure = answer.failure {
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
    private let onComplete: @Sendable (URLSessionTask, TaskAnswer) -> Void

    init(
        onProgress: @escaping @Sendable (URLSessionTask, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (URLSessionTask, TaskAnswer) -> Void
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
        onComplete(task, TaskAnswer(status: response?.statusCode, headers: headers, body: body, failure: error))
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
    /// What pause, resume and cancel reach: a single PUT's task, or a multipart upload's parts.
    struct Controls: Sendable {
        let pause: @Sendable () -> Void
        let resume: @Sendable () -> Void
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var result: Result<CompletedUpload, VidexoError>?
    private var waiters: [CheckedContinuation<CompletedUpload, Error>] = []
    private var controls: Controls?
    private var cancelled = false

    init() {}

    fileprivate func started(_ controls: Controls) {
        lock.lock()
        self.controls = controls
        let cancel = cancelled
        lock.unlock()
        if cancel { controls.cancel() }
    }

    fileprivate func finish(_ result: Result<CompletedUpload, VidexoError>) {
        lock.lock()
        let waiting = waiters
        waiters = []
        self.result = result
        controls = nil
        lock.unlock()
        for waiter in waiting { waiter.resume(with: result.mapError { $0 as Error }) }
    }

    private var current: Controls? {
        lock.lock()
        defer { lock.unlock() }
        return controls
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

    /// Stops sending. A single upload keeps its connection; its URL allows one PUT, so when the
    /// connection ends while paused, the upload fails and the next try needs a new upload. A multipart
    /// upload holds its parts under way and starts no more.
    public func pause() {
        current?.pause()
    }

    public func resume() {
        current?.resume()
    }

    /// Ends the upload, with `aborted` as its result. A single upload's URL is used up once bytes have
    /// been sent; a multipart upload is aborted, its received parts deleted.
    public func cancel() {
        lock.lock()
        cancelled = true
        let controls = controls
        lock.unlock()
        controls?.cancel()
    }
}

/// Sends a file to an upload, from a client token or from your backend, while the app runs: one PUT to
/// a single upload's URL, or the parts of a multipart upload. For an upload that goes on when the app is
/// suspended, see `BackgroundUploader`.
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
            onComplete: { _, answer in
                let result = completedUpload(answer)
                // A small file can end with no progress told at all, and the caller's bar should reach its end.
                if case .success = result { onProgress?(UploadProgress(loaded: total, total: total)) }
                handle.finish(result)
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout ?? uploadURLLifetime
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.uploadTask(with: putRequest(uploadURL, contentType: contentType ?? contentTypeOf(file)), fromFile: file)
        handle.started(UploadHandle.Controls(pause: { task.suspend() }, resume: { task.resume() }, cancel: { task.cancel() }))
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

    /// Starts sending `file` to `upload`, a multipart one or a single one, and answers its handle. A
    /// multipart upload reads its received parts first, so starting it again with the same file after
    /// a lost connection or a relaunch sends only the parts still missing. Keep the `Upload` for that:
    /// it is `Codable`.
    /// - Parameters:
    ///   - contentType: A single upload's type; by the file's extension when nil. A multipart upload's
    ///     was set when it was created.
    ///   - partsAtOnce: Parts sent at once, 1 to 10.
    ///   - maxRetries: Times each part and each call is sent again after a lost connection, a timeout, a
    ///     `429`, a `502` to `504`, or while another request still sends the part. Any other refusal ends
    ///     the upload, which can then be started again.
    ///   - timeout: Seconds one part, or a single upload's PUT, may take; one hour when nil.
    ///   - onProgress: The bytes received and on their way, never less than told before; an upload that
    ///     succeeds always ends with `loaded` equal to `total`.
    public func start(
        file: URL,
        upload: Upload,
        contentType: String? = nil,
        partsAtOnce: Int = 3,
        maxRetries: Int = 4,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) throws -> UploadHandle {
        guard upload.multipart != nil else {
            return try start(file: file, to: upload.uploadURL, contentType: contentType, timeout: timeout, onProgress: onProgress)
        }
        let transfer = try MultipartTransfer(
            file: file,
            upload: upload,
            partsAtOnce: partsAtOnce,
            maxRetries: maxRetries,
            timeout: timeout,
            onProgress: onProgress
        )
        let handle = UploadHandle()
        let running = Task {
            do {
                handle.finish(.success(try await transfer.run()))
            } catch let error as VidexoError {
                handle.finish(.failure(error))
            } catch {
                handle.finish(.failure(sdkError(.aborted, "The upload was aborted.")))
            }
        }
        handle.started(UploadHandle.Controls(
            pause: { transfer.pause() },
            resume: { transfer.resume() },
            cancel: {
                transfer.cancel()
                running.cancel()
            }
        ))
        return handle
    }

    /// `start` for `upload`, then its completed upload. Cancelling the calling task ends the upload, and
    /// aborts a multipart one.
    public func send(
        file: URL,
        upload: Upload,
        contentType: String? = nil,
        partsAtOnce: Int = 3,
        maxRetries: Int = 4,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> CompletedUpload {
        let handle = try start(
            file: file,
            upload: upload,
            contentType: contentType,
            partsAtOnce: partsAtOnce,
            maxRetries: maxRetries,
            timeout: timeout,
            onProgress: onProgress
        )
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
