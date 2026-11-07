import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Uploads that go on when the app is suspended or ended, through a background URLSession: the system
// sends the file and wakes the app with the result. All an upload needs to be known again after a
// relaunch travels in its task's description (the SDK's id and your tag), never a token.

/// An upload of a `BackgroundUploader`.
public struct BackgroundUpload: Equatable, Sendable {
    /// The SDK's id of this upload, the same after a relaunch.
    public let id: String
    /// What you passed to `start`, to know the upload again after a relaunch.
    public let tag: String?
    /// How far it has come, when this was read.
    public let progress: UploadProgress
}

/// What a `BackgroundUploader` reports.
public enum BackgroundUploadEvent: Sendable {
    /// How far an upload has come. While the bytes go out this is told when the system reports it, which
    /// may be never for a small or fast upload. An upload that succeeds always gets one with `loaded`
    /// equal to `total`, right before its `finished`; one that fails does not.
    case progress(BackgroundUpload)
    /// The end of an upload, also one started before a relaunch. The result is told once: keep it.
    /// The file may be deleted now.
    case finished(BackgroundUpload, Result<CompletedUpload, VidexoError>)
}

private struct TaskDescription: Codable {
    let id: String
    let tag: String?
}

/// Sends files to one-time upload URLs through a background session.
///
/// Make one for an identifier, early in the app's launch and for the life of the process, so that the
/// results of uploads started before a relaunch find it. The file must stay inside the app's sandbox
/// until `finished`: a file from a picker is outside it, so copy it first. A background session never
/// retries through the SDK, but the system may repeat a PUT after a lost connection; the upload URL
/// refuses a second PUT, and that refusal is the result.
public final class BackgroundUploader: @unchecked Sendable {
    private let session: URLSession
    private let delegate: UploadDelegate
    private let lock = NSLock()
    private var finishEvents: (() -> Void)?

    #if !canImport(FoundationNetworking)
    /// - Parameters:
    ///   - identifier: The background session's identifier, unique in the app.
    ///   - allowsCellularAccess: Whether an upload may use a cellular network.
    ///   - isDiscretionary: Whether the system may wait for a good moment, such as Wi-Fi and power.
    ///   - onEvent: Called on a background queue, from the first moment: also for earlier uploads.
    public convenience init(
        identifier: String,
        allowsCellularAccess: Bool = true,
        isDiscretionary: Bool = false,
        onEvent: @escaping @Sendable (BackgroundUploadEvent) -> Void
    ) {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.isDiscretionary = isDiscretionary
        configuration.sessionSendsLaunchEvents = true
        self.init(configuration: configuration, onEvent: onEvent)
    }
    #endif

    init(configuration: URLSessionConfiguration, onEvent: @escaping @Sendable (BackgroundUploadEvent) -> Void) {
        configuration.timeoutIntervalForResource = uploadURLLifetime
        delegate = UploadDelegate(
            onProgress: { task, sent, expected in
                guard let upload = BackgroundUploader.upload(of: task, sent: sent, expected: expected) else { return }
                onEvent(.progress(upload))
            },
            onComplete: { task, result in
                guard case let .success(completed) = result else {
                    guard let upload = BackgroundUploader.upload(of: task, sent: task.countOfBytesSent, expected: task.countOfBytesExpectedToSend) else { return }
                    return onEvent(.finished(upload, result))
                }
                // A small or fast upload can end with no progress told at all, and the caller's bar should reach its end.
                let total = task.countOfBytesExpectedToSend > 0 ? task.countOfBytesExpectedToSend : Int64(completed.sizeBytes)
                guard let upload = BackgroundUploader.upload(of: task, sent: total, expected: total) else { return }
                onEvent(.progress(upload))
                onEvent(.finished(upload, result))
            }
        )
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        #if !canImport(FoundationNetworking)
        delegate.onFinishedEvents = { [weak self] in self?.callFinishEvents() }
        #endif
    }

    private static func upload(of task: URLSessionTask, sent: Int64, expected: Int64) -> BackgroundUpload? {
        guard
            let text = task.taskDescription,
            let description = try? JSONDecoder().decode(TaskDescription.self, from: Data(text.utf8))
        else { return nil }
        return BackgroundUpload(id: description.id, tag: description.tag, progress: UploadProgress(loaded: sent, total: expected))
    }

    /// Starts sending `file` to a one-time upload URL, and answers the upload.
    /// - Parameters:
    ///   - contentType: The type the upload was created with; by the file's extension when nil.
    ///   - tag: Your own short text to know the upload again after a relaunch. It is stored on the
    ///     device with the task; never put a token in it.
    @discardableResult
    public func start(file: URL, to uploadURL: URL, contentType: String? = nil, tag: String? = nil) throws -> BackgroundUpload {
        let total = try fileSize(file)
        let id = UUID().uuidString
        let description = try JSONEncoder().encode(TaskDescription(id: id, tag: tag))
        let task = session.uploadTask(with: putRequest(uploadURL, contentType: contentType ?? contentTypeOf(file)), fromFile: file)
        task.taskDescription = String(decoding: description, as: UTF8.self)
        task.resume()
        return BackgroundUpload(id: id, tag: tag, progress: UploadProgress(loaded: 0, total: total))
    }

    private func tasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    /// The uploads under way, also those started before a relaunch.
    public func uploads() async -> [BackgroundUpload] {
        await tasks().compactMap { task in
            guard task.state != .completed, task.state != .canceling else { return nil }
            return BackgroundUploader.upload(of: task, sent: task.countOfBytesSent, expected: task.countOfBytesExpectedToSend)
        }
    }

    private func task(_ id: String) async -> URLSessionTask? {
        await tasks().first { task in
            BackgroundUploader.upload(of: task, sent: 0, expected: 0)?.id == id
        }
    }

    /// Stops sending. The URL allows one PUT: when the connection ends while paused, the upload fails
    /// and the next try needs a new upload.
    public func pause(_ id: String) async {
        await task(id)?.suspend()
    }

    public func resume(_ id: String) async {
        await task(id)?.resume()
    }

    /// Ends the upload, with `aborted` as its result.
    public func cancel(_ id: String) async {
        await task(id)?.cancel()
    }

    /// Call this from `application(_:handleEventsForBackgroundURLSession:completionHandler:)` for this
    /// uploader's identifier. The handler is called on the main queue once every event has been told.
    public func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        finishEvents = completionHandler
    }

    private func callFinishEvents() {
        lock.lock()
        let handler = finishEvents
        finishEvents = nil
        lock.unlock()
        guard let handler else { return }
        let box = MainQueueHandler(handler)
        DispatchQueue.main.async { box.call() }
    }
}

/// The system's completion handler on its way to the main queue.
private struct MainQueueHandler: @unchecked Sendable {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}
