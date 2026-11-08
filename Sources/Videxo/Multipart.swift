import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// A multipart upload (https://videxo.io/docs/files#multipart-uploads): the file goes in parts, each its
// own PUT that can be sent again, then one POST completes it. `GET upload_url` lists the parts received,
// so a send that stopped resumes with the parts still missing. Each part is copied from its range of the
// file into a part file of its own (a background session sends only files), never the whole file.

/// The largest file sent with one PUT; `uploads.upload` sends a larger one as a multipart upload.
public let singleUploadMaxBytes: Int64 = 100_000_000

/// The largest part and the most parts storage takes: a plan past them is not one the API makes.
private let maxPartBytes: Int64 = 5 * 1024 * 1024 * 1024
private let maxPartCount = 10_000
/// Bytes read from the file at a time while a part file is written.
private let copyChunkBytes = 1_048_576
/// How long a part that another request is still sending is waited for, when the API names no time.
let partInFlightWait: TimeInterval = 5
/// Reads of an upload whose completion another request is running (`409 upload_used`), 5 seconds
/// apart, before giving up: a completion that stalls is taken over by the API after 10 minutes.
let completionWaits = 24

/// Where each part of a file lies.
struct PartLayout: Equatable, Sendable {
    let sizeBytes: Int64
    let partSize: Int64
    let partCount: Int

    func offset(of part: Int) -> Int64 { Int64(part - 1) * partSize }
    func length(of part: Int) -> Int64 { min(partSize, sizeBytes - offset(of: part)) }
}

/// The layout of a multipart upload for a file of `fileSize` bytes; refuses a plan the SDK cannot use.
func partLayout(_ plan: MultipartPlan, fileSize: Int64) throws -> PartLayout {
    let partSize = Int64(plan.partSizeBytes)
    guard partSize >= 1, partSize <= maxPartBytes, (1...maxPartCount).contains(plan.partCount) else {
        throw sdkError(.invalidResponse, "The upload's parts are \(plan.partSizeBytes) bytes in \(plan.partCount) parts, which the SDK cannot send.")
    }
    guard fileSize > 0, (fileSize + partSize - 1) / partSize == Int64(plan.partCount) else {
        throw sdkError(.invalidArgument, "The file is \(fileSize) bytes, which does not fit the upload's \(plan.partCount) parts of \(plan.partSizeBytes) bytes: send the file the upload was created for.")
    }
    guard plan.partURLTemplate.contains("{part_number}") else {
        throw sdkError(.invalidResponse, "The upload's part URL template has no {part_number}.")
    }
    return PartLayout(sizeBytes: fileSize, partSize: partSize, partCount: plan.partCount)
}

/// The part numbers an upload's status lists as received, once the status is checked against the file.
func receivedParts(_ status: MultipartUploadStatus, layout: PartLayout) throws -> Set<Int> {
    guard Int64(status.sizeBytes) == layout.sizeBytes else {
        throw sdkError(.invalidArgument, "The file is \(layout.sizeBytes) bytes, but the upload declared \(status.sizeBytes): send the file the upload was created for.")
    }
    guard Int64(status.partSizeBytes) == layout.partSize, status.partCount == layout.partCount else {
        throw sdkError(.invalidResponse, "The upload lists parts of \(status.partSizeBytes) bytes in \(status.partCount) parts, not the \(layout.partSize) bytes in \(layout.partCount) parts it was created with.")
    }
    var received = Set<Int>()
    for part in status.parts {
        guard (1...layout.partCount).contains(part.partNumber) else {
            throw sdkError(.invalidResponse, "The upload lists part \(part.partNumber), past its \(layout.partCount) parts.")
        }
        // A part of another size was cut from another file, or the plan changed: none of the file can be trusted to fit.
        guard Int64(part.sizeBytes) == layout.length(of: part.partNumber) else {
            throw sdkError(.invalidResponse, "The upload lists part \(part.partNumber) with \(part.sizeBytes) bytes, but that part of the file is \(layout.length(of: part.partNumber)): create a new upload.")
        }
        received.insert(part.partNumber)
    }
    return received
}

/// The URL of part `number`.
func partURL(_ plan: MultipartPlan, _ number: Int) throws -> URL {
    guard let url = URL(string: plan.partURLTemplate.replacingOccurrences(of: "{part_number}", with: String(number))) else {
        throw sdkError(.invalidResponse, "The upload's part URL template is not a URL.")
    }
    return url
}

/// Copies part `number` of `file` to `destination`, a chunk at a time; answers its `Content-Digest`
/// (RFC 9530), which the API checks. Without CryptoKit (Linux, where only the tests run) the part goes
/// without one. Refuses a file that changed size since the upload was planned.
func writePart(of file: URL, layout: PartLayout, number: Int, to destination: URL) throws -> String? {
    guard try fileSize(file) == layout.sizeBytes else {
        throw sdkError(.invalidArgument, "The file changed size since the upload was created: create a new upload.")
    }
    guard let input = try? FileHandle(forReadingFrom: file) else {
        throw sdkError(.invalidArgument, "The file to upload cannot be read: \(file.lastPathComponent).")
    }
    defer { try? input.close() }
    try? FileManager.default.removeItem(at: destination)
    guard FileManager.default.createFile(atPath: destination.path, contents: nil), let output = try? FileHandle(forWritingTo: destination) else {
        throw sdkError(.invalidArgument, "A part of the upload cannot be written to \(destination.deletingLastPathComponent().lastPathComponent).")
    }
    defer { try? output.close() }
    #if canImport(CryptoKit)
    var hash = SHA256()
    #endif
    var left = layout.length(of: number)
    do {
        try input.seek(toOffset: UInt64(layout.offset(of: number)))
        while left > 0 {
            let chunk = try input.read(upToCount: Int(min(Int64(copyChunkBytes), left))) ?? Data()
            if chunk.isEmpty { break }
            #if canImport(CryptoKit)
            hash.update(data: chunk)
            #endif
            try output.write(contentsOf: chunk)
            left -= Int64(chunk.count)
        }
    } catch {
        throw sdkError(.invalidArgument, "Part \(number) of the file cannot be read or written.")
    }
    guard left == 0 else { throw sdkError(.invalidArgument, "The file ended before part \(number): create a new upload.") }
    #if canImport(CryptoKit)
    return "sha-256=:\(Data(hash.finalize()).base64EncodedString()):"
    #else
    return nil
    #endif
}

func partRequest(_ url: URL, digest: String?) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    if let digest { request.setValue(digest, forHTTPHeaderField: "Content-Digest") }
    return request
}

func completeRequest(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    return request
}

/// What a task of a session that sends files got back.
struct TaskAnswer: Sendable {
    let status: Int?
    let headers: HTTPHeaders
    let body: Data
    let failure: Error?

    var error: VidexoError? {
        guard let status, !(200..<300).contains(status) else { return nil }
        return errorFromResponse(status: status, headers: headers, body: body)
    }
}

/// What to do after one PUT of a part.
enum PartOutcome {
    /// It arrived, now or before (an answer lost after the part arrived).
    case received
    /// Send it again, after this wait (nil: the caller's backoff).
    case again(after: TimeInterval?, VidexoError)
    case failed(VidexoError)
}

/// A part is sent again after a lost connection, a timeout, a 429, a 502 to 504 and while another request
/// still sends it; a refusal of the part itself (any other 4xx) is final, so it is never sent forever.
func partOutcome(_ answer: TaskAnswer, now: Date = Date()) -> PartOutcome {
    if let failure = answer.failure {
        if isCancellation(failure) { return .failed(sdkError(.aborted, "The upload was aborted.")) }
        if (failure as? URLError)?.code == .timedOut { return .again(after: nil, sdkError(.timeout, "A part of the upload did not finish in time.")) }
        // Only the fixed sentence: a URL error's details hold the part's URL.
        return .again(after: nil, sdkError(.networkError, "A part of the upload failed: the connection was lost."))
    }
    guard let status = answer.status else { return .again(after: nil, sdkError(.networkError, "A part of the upload got no answer.")) }
    guard let error = answer.error else { return .received }
    if status == 409, error.reason == "part_received" { return .received }
    if status == 409, error.reason == "part_in_flight" { return .again(after: partInFlightWait, error) }
    if [429, 502, 503, 504].contains(status) {
        let retryAfter = retryAfterSeconds(answer.headers["retry-after"], now: now)
        if let retryAfter, retryAfter > maxRetryAfterSeconds { return .failed(error) }
        return .again(after: retryAfter.map(TimeInterval.init), error)
    }
    return .failed(error)
}

/// Turns the signature of an upload's URLs into a placeholder, for an error's text.
func redactingSignature(of url: URL) -> @Sendable (String) -> String {
    let query = url.query ?? ""
    return { text in query.isEmpty ? text : text.replacingOccurrences(of: query, with: "[signature]") }
}

/// One session for every upload's calls: they hold no credential, so nothing is kept between them that matters.
private let multipartCallSession = URLSession(configuration: .ephemeral)

/// The calls of a multipart upload besides its parts: the status, the completion and the abort, with the
/// client's retries. None holds a credential: the upload's URLs are its capability.
struct MultipartCalls: Sendable {
    let upload: Upload
    let plan: MultipartPlan
    let transport: any VidexoTransport
    let maxRetries: Int
    let environment: SDKEnvironment

    init(upload: Upload, plan: MultipartPlan, maxRetries: Int, environment: SDKEnvironment = SDKEnvironment()) {
        self.upload = upload
        self.plan = plan
        self.maxRetries = maxRetries
        self.environment = environment
        transport = URLSessionTransport(session: multipartCallSession)
    }

    private func call<T: Decodable>(_ method: String, _ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let answer = try await sendWithRetries(
            transport,
            request,
            maxRetries: maxRetries,
            timeout: 60,
            environment: environment,
            redact: redactingSignature(of: url)
        )
        guard answer.isOK else { throw errorFromResponse(status: answer.status, headers: answer.headers, body: answer.body) }
        guard let value = try? apiDecoder().decode(T.self, from: answer.body) else {
            throw sdkError(.invalidResponse, "The upload URL answered with a body the SDK could not read.", status: answer.status, body: answer.body)
        }
        return value
    }

    /// `GET upload_url`: the state and the parts received.
    func status() async throws -> MultipartUploadStatus { try await call("GET", upload.uploadURL) }

    /// `POST complete_url`: joins the parts.
    func complete() async throws -> CompletedUpload { try await call("POST", plan.completeURL) }

    /// `DELETE upload_url`: aborts the upload. Run outside the caller's task, so a cancelled caller still aborts.
    func abort() async {
        struct Deleted: Decodable { let deleted: Bool }
        let calls = self
        let aborting = Task.detached {
            let _: Deleted? = try? await calls.call("DELETE", calls.upload.uploadURL)
        }
        await aborting.value
    }
}

/// A file sent as a multipart upload while the app runs: a few parts at a time, each sent again on its
/// own, then completed. Cancelling aborts the upload.
final class MultipartTransfer: @unchecked Sendable {
    private let file: URL
    private let layout: PartLayout
    private let plan: MultipartPlan
    private let calls: MultipartCalls
    private let partsAtOnce: Int
    private let maxRetries: Int
    private let environment: SDKEnvironment
    private let onProgress: (@Sendable (UploadProgress) -> Void)?
    private let session: URLSession
    private let delegate: UploadDelegate
    private let folder: URL

    private let lock = NSLock()
    private var answers: [Int: CheckedContinuation<TaskAnswer, Never>] = [:]
    private var running: [Int: URLSessionTask] = [:]
    private var sending: [Int: Int64] = [:]
    private var receivedBytes: Int64 = 0
    private var reported: Int64 = -1
    private var paused = false
    private var unpause: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    /// Set when one part failed for good: the other parts stop, without aborting the upload.
    private var stopping = false
    /// Held while progress is told, so two parts never tell it out of order.
    private let telling = NSLock()

    init(
        file: URL,
        upload: Upload,
        partsAtOnce: Int,
        maxRetries: Int,
        timeout: TimeInterval?,
        environment: SDKEnvironment = SDKEnvironment(),
        onProgress: (@Sendable (UploadProgress) -> Void)?
    ) throws {
        guard let plan = upload.multipart else { throw sdkError(.invalidArgument, "The upload was not created with multipart.") }
        layout = try partLayout(plan, fileSize: try fileSize(file))
        self.file = file
        self.plan = plan
        self.partsAtOnce = max(1, min(partsAtOnce, 10))
        self.maxRetries = max(0, maxRetries)
        self.environment = environment
        self.onProgress = onProgress
        calls = MultipartCalls(upload: upload, plan: plan, maxRetries: self.maxRetries, environment: environment)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("videxo-parts-\(UUID().uuidString)")
        let owner = WeakOwner<MultipartTransfer>()
        delegate = UploadDelegate(
            onProgress: { task, sent, _ in owner.value?.sent(sent, by: task) },
            onComplete: { task, answer in owner.value?.ended(task, answer) }
        )
        let configuration = URLSessionConfiguration.ephemeral
        // A part's claim lasts an hour: past it the API takes the part from another request.
        configuration.timeoutIntervalForResource = timeout ?? uploadURLLifetime
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        owner.value = self
    }

    /// Sends the parts not yet received and completes the upload.
    func run() async throws -> CompletedUpload {
        defer {
            session.finishTasksAndInvalidate()
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for round in 0..<2 {
                let status = try await calls.status()
                if status.state == "complete" { return try await finished(complete()) }
                let received = try receivedParts(status, layout: layout)
                setReceived(received)
                try await sendParts((1...layout.partCount).filter { !received.contains($0) })
                do {
                    return try await finished(complete())
                } catch let error as VidexoError where error.reason == "upload_incomplete" && round == 0 {
                    // The API found a part replaced by a request that crashed and freed the received parts: once more.
                    continue
                }
            }
            throw sdkError(.invalidResponse, "The upload stayed incomplete after its parts were sent again.")
        } catch {
            if isCancelled {
                await calls.abort()
                throw sdkError(.aborted, "The upload was aborted.")
            }
            throw error
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || Task.isCancelled
    }

    private func finished(_ completed: CompletedUpload) -> CompletedUpload {
        lock.lock()
        receivedBytes = layout.sizeBytes
        sending = [:]
        reported = min(reported, layout.sizeBytes - 1)
        lock.unlock()
        report()
        return completed
    }

    /// `POST complete_url`. When another completion of the upload is running (`409 upload_used`, as after
    /// a completion whose connection was lost), its state is read until it ends: `complete` answers the
    /// completed upload, `pending` (that completion failed) is completed again, and a wait past
    /// `completionWaits` reads gives the refusal back.
    private func complete() async throws -> CompletedUpload {
        var waits = 0
        while true {
            do {
                return try await calls.complete()
            } catch let error as VidexoError where error.reason == "upload_used" {
                while true {
                    guard waits < completionWaits else { throw error }
                    waits += 1
                    do {
                        try await environment.sleep(partInFlightWait)
                    } catch {
                        throw sdkError(.aborted, "The upload was aborted.")
                    }
                    let status = try await calls.status()
                    if status.state == "uploading" { continue }
                    if status.state == "failed" { throw error }
                    break
                }
            }
        }
    }

    /// Sends the parts, `partsAtOnce` at a time. The first part that fails for good stops the others.
    private func sendParts(_ missing: [Int]) async throws {
        let queue = PartQueue(missing)
        startParts()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<min(partsAtOnce, missing.count) {
                group.addTask {
                    while !self.isStopping, let number = queue.next() { try await self.sendPart(number) }
                }
            }
            do {
                while try await group.next() != nil {}
            } catch {
                stopParts()
                group.cancelAll()
                throw error
            }
        }
    }

    private func startParts() {
        lock.lock()
        defer { lock.unlock() }
        stopping = false
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping || cancelled || Task.isCancelled
    }

    /// Ends the parts under way after one failed for good; the upload stays, so it can be resumed.
    private func stopParts() {
        lock.lock()
        stopping = true
        let waiting = unpause
        unpause = []
        let tasks = Array(running.values)
        lock.unlock()
        for task in tasks { task.cancel() }
        for continuation in waiting { continuation.resume() }
    }

    private func sendPart(_ number: Int) async throws {
        let partFile = folder.appendingPathComponent("part-\(number)")
        defer { try? FileManager.default.removeItem(at: partFile) }
        let digest = try writePart(of: file, layout: layout, number: number, to: partFile)
        let request = partRequest(try partURL(plan, number), digest: digest)
        var attempt = 0
        while true {
            try await waitWhilePaused()
            if isStopping { throw sdkError(.aborted, "The upload was aborted.") }
            let answer = await put(request, from: partFile)
            switch partOutcome(answer, now: environment.now()) {
            case .received:
                partStopped(number, arrived: true)
                return
            case let .again(after, error):
                partStopped(number, arrived: false)
                guard attempt < maxRetries, !isCancelled else { throw isCancelled ? sdkError(.aborted, "The upload was aborted.") : error }
                do {
                    try await environment.sleep(after ?? backoffSeconds(attempt: attempt, random: environment.random()))
                } catch {
                    throw sdkError(.aborted, "The upload was aborted.")
                }
                attempt += 1
            case let .failed(error):
                throw error
            }
        }
    }

    private func setReceived(_ received: Set<Int>) {
        lock.lock()
        receivedBytes = received.reduce(0) { $0 + layout.length(of: $1) }
        lock.unlock()
        report()
    }

    private func partStopped(_ number: Int, arrived: Bool) {
        lock.lock()
        sending[number] = nil
        if arrived { receivedBytes += layout.length(of: number) }
        lock.unlock()
        report()
    }

    private func put(_ request: URLRequest, from partFile: URL) async -> TaskAnswer {
        await withCheckedContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: partFile)
            lock.lock()
            answers[task.taskIdentifier] = continuation
            running[task.taskIdentifier] = task
            let stop = cancelled || stopping
            lock.unlock()
            if stop { task.cancel() }
            task.resume()
        }
    }

    private func ended(_ task: URLSessionTask, _ answer: TaskAnswer) {
        lock.lock()
        let continuation = answers.removeValue(forKey: task.taskIdentifier)
        running[task.taskIdentifier] = nil
        lock.unlock()
        continuation?.resume(returning: answer)
    }

    private func sent(_ bytes: Int64, by task: URLSessionTask) {
        guard let number = Int(task.originalRequest?.url?.pathComponents.last ?? "") else { return }
        lock.lock()
        sending[number] = bytes
        lock.unlock()
        report()
    }

    /// The bytes received and on their way, never less than told before: a part sent again starts over.
    /// Told under `telling`, and compared there, so a later value is never told before an earlier one.
    private func report() {
        telling.lock()
        defer { telling.unlock() }
        lock.lock()
        let loaded = min(layout.sizeBytes, receivedBytes + sending.values.reduce(0, +))
        guard loaded > reported else { return lock.unlock() }
        reported = loaded
        lock.unlock()
        onProgress?(UploadProgress(loaded: loaded, total: layout.sizeBytes))
    }

    private func waitWhilePaused() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if paused && !cancelled && !stopping {
                unpause.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        paused = true
        for task in running.values { task.suspend() }
    }

    func resume() {
        lock.lock()
        paused = false
        let waiting = unpause
        unpause = []
        for task in running.values { task.resume() }
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let waiting = unpause
        unpause = []
        let tasks = Array(running.values)
        lock.unlock()
        for task in tasks { task.cancel() }
        for continuation in waiting { continuation.resume() }
    }
}

/// The part numbers still to send, handed out one at a time.
private final class PartQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: ArraySlice<Int>

    init(_ parts: [Int]) {
        self.parts = parts[...]
    }

    func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return parts.popFirst()
    }
}

/// A delegate's way back to the object that owns its session, which the session's delegate must not keep.
final class WeakOwner<Owner: AnyObject>: @unchecked Sendable {
    weak var value: Owner?
}
