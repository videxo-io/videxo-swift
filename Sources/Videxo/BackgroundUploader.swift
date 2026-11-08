import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Uploads that go on when the app is suspended or ended, through a background URLSession: the system
// sends the file and wakes the app with the result. A single upload is one task, and all it needs to be
// known again after a relaunch travels in its task's description (the SDK's id and your tag), never a
// token. A multipart upload is one task per part, a few at a time, then one for its completion; what it
// needs after a relaunch (the file's path, the `Upload` with its URLs, the parts received) is kept in a
// small file of its own in the app's Application Support folder until it ends.

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
    /// A multipart upload's part number, or 0 for its completion; nil for a single upload.
    var part: Int?
}

/// What a multipart upload needs after a relaunch. It holds the upload's URLs, its capability, so it
/// stays in the app's own Application Support folder, and goes when the upload ends.
private struct Manifest: Codable {
    let id: String
    let tag: String?
    /// The file's path, from the home folder when it is inside it: an app's container moves between launches.
    let file: String
    let upload: Upload
    var received: [Int]
    /// Sends again used, by part number; 0 is the completion.
    var attempts: [Int: Int]
    /// Times the parts were read again after a completion found some missing.
    var resyncs: Int
}

/// A multipart upload under way in this process.
private struct MultipartState {
    var manifest: Manifest
    let layout: PartLayout
    let plan: MultipartPlan
    /// Parts with a task, and 0 while the completion has one.
    var inFlight: Set<Int> = []
    var sending: [Int: Int64] = [:]
    var reported: Int64 = 0
    var paused = false
    /// Read from its file at launch, until the session's tasks are known: ends are taken, nothing is started.
    var restoring = false
    /// Parts (0: the completion) whose end came while restoring: the snapshot of the session's tasks may
    /// have been taken before they ended, so they are not under way, whatever it says.
    var endedWhileRestoring: Set<Int> = []

    var receivedBytes: Int64 { manifest.received.reduce(0) { $0 + layout.length(of: $1) } }
    var loaded: Int64 { min(layout.sizeBytes, receivedBytes + sending.values.reduce(0, +)) }
}

private func storedPath(_ file: URL) -> String {
    let home = NSHomeDirectory()
    let path = file.standardizedFileURL.path
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

private func fileURL(stored: String) -> URL {
    stored.hasPrefix("~/") ? URL(fileURLWithPath: NSHomeDirectory() + stored.dropFirst()) : URL(fileURLWithPath: stored)
}

/// Sends files to upload URLs through a background session.
///
/// Make one for an identifier, early in the app's launch and for the life of the process, so that the
/// results of uploads started before a relaunch find it. The file must stay inside the app's sandbox
/// until `finished`: a file from a picker is outside it, so copy it first.
///
/// A single upload's URL takes one PUT: a background session never retries it through the SDK, but the
/// system may repeat a PUT after a lost connection; the URL refuses a second PUT, and that refusal is
/// the result. A multipart upload sends each part as its own task, and sends a part again after a lost
/// connection, a timeout, a `429` or a `502` to `504`, up to `maxRetries` times.
public final class BackgroundUploader: @unchecked Sendable {
    private let session: URLSession
    private let delegate: UploadDelegate
    private let lock = NSLock()
    private var finishEvents: (() -> Void)?
    private let onEvent: @Sendable (BackgroundUploadEvent) -> Void
    private let folder: URL
    private let partsAtOnce: Int
    private let maxRetries: Int
    private let environment: SDKEnvironment
    /// Every multipart upload's state is read and changed on this queue only.
    private let queue = DispatchQueue(label: "io.videxo.background-uploader")
    private var multipart: [String: MultipartState] = [:]
    /// Uploads read at launch whose file is gone or changed, ended once the session's tasks are known.
    private var broken: [(Manifest, VidexoError)] = []
    /// Work on `queue` that outlives the event that started it (the restore, a read of the parts):
    /// the system's completion handler waits for it, so the app is not suspended with work half done.
    private var outstanding = 0
    private var finishRequested = false
    /// Lists the session's tasks for the restore; a test hands the snapshot in itself.
    typealias ListTasks = (@escaping ([URLSessionTask]) -> Void) -> Void
    private let listTasks: ListTasks?

    #if !canImport(FoundationNetworking)
    /// - Parameters:
    ///   - identifier: The background session's identifier, unique in the app.
    ///   - allowsCellularAccess: Whether an upload may use a cellular network.
    ///   - isDiscretionary: Whether the system may wait for a good moment, such as Wi-Fi and power.
    ///   - partsAtOnce: A multipart upload's parts sent at once, 1 to 10.
    ///   - maxRetries: Times a multipart upload's part, or its completion, is sent again.
    ///   - onEvent: Called on a background queue, from the first moment: also for earlier uploads.
    public convenience init(
        identifier: String,
        allowsCellularAccess: Bool = true,
        isDiscretionary: Bool = false,
        partsAtOnce: Int = 3,
        maxRetries: Int = 4,
        onEvent: @escaping @Sendable (BackgroundUploadEvent) -> Void
    ) {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsCellularAccess = allowsCellularAccess
        configuration.isDiscretionary = isDiscretionary
        configuration.sessionSendsLaunchEvents = true
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let name = String(identifier.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        self.init(
            configuration: configuration,
            folder: support.appendingPathComponent("Videxo/BackgroundUploads/\(name)"),
            partsAtOnce: partsAtOnce,
            maxRetries: maxRetries,
            onEvent: onEvent
        )
    }
    #endif

    init(
        configuration: URLSessionConfiguration,
        folder: URL? = nil,
        partsAtOnce: Int = 3,
        maxRetries: Int = 4,
        environment: SDKEnvironment = SDKEnvironment(),
        listTasks: ListTasks? = nil,
        onEvent: @escaping @Sendable (BackgroundUploadEvent) -> Void
    ) {
        configuration.timeoutIntervalForResource = uploadURLLifetime
        self.listTasks = listTasks
        self.onEvent = onEvent
        self.folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("videxo-uploads-\(UUID().uuidString)")
        self.partsAtOnce = max(1, min(partsAtOnce, 10))
        self.maxRetries = max(0, maxRetries)
        self.environment = environment
        let owner = WeakOwner<BackgroundUploader>()
        delegate = UploadDelegate(
            onProgress: { task, sent, expected in owner.value?.progressed(task, sent: sent, expected: expected) },
            onComplete: { task, answer in owner.value?.ended(task, answer) }
        )
        // The uploads of an earlier process are known before the session can tell any of their ends.
        // The restore's work is counted before any event can reach this uploader, so the system's
        // completion handler of the wake that launched the app waits for it.
        (multipart, broken) = BackgroundUploader.load(from: self.folder.appendingPathComponent("manifests"))
        let restoring = !multipart.isEmpty || !broken.isEmpty
        outstanding = restoring ? 1 : 0
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        owner.value = self
        #if !canImport(FoundationNetworking)
        delegate.onFinishedEvents = { owner.value?.systemFinishedEvents() }
        #endif
        if restoring { restore() }
    }

    private static func description(of task: URLSessionTask) -> TaskDescription? {
        guard let text = task.taskDescription else { return nil }
        return try? JSONDecoder().decode(TaskDescription.self, from: Data(text.utf8))
    }

    private static func upload(of task: URLSessionTask, sent: Int64, expected: Int64) -> BackgroundUpload? {
        guard let description = description(of: task), description.part == nil else { return nil }
        return BackgroundUpload(id: description.id, tag: description.tag, progress: UploadProgress(loaded: sent, total: expected))
    }

    private func progressed(_ task: URLSessionTask, sent: Int64, expected: Int64) {
        guard let description = BackgroundUploader.description(of: task) else { return }
        guard let part = description.part else {
            guard let upload = BackgroundUploader.upload(of: task, sent: sent, expected: expected) else { return }
            return onEvent(.progress(upload))
        }
        guard part > 0 else { return }
        queue.async { [self] in
            guard var state = multipart[description.id], state.inFlight.contains(part) else { return }
            state.sending[part] = sent
            multipart[description.id] = state
            tellProgress(description.id)
        }
    }

    private func ended(_ task: URLSessionTask, _ answer: TaskAnswer) {
        guard let description = BackgroundUploader.description(of: task) else { return }
        guard let part = description.part else {
            let result = completedUpload(answer)
            guard case let .success(completed) = result else {
                guard let upload = BackgroundUploader.upload(of: task, sent: task.countOfBytesSent, expected: task.countOfBytesExpectedToSend) else { return }
                return onEvent(.finished(upload, result))
            }
            // A small or fast upload can end with no progress told at all, and the caller's bar should reach its end.
            let total = task.countOfBytesExpectedToSend > 0 ? task.countOfBytesExpectedToSend : Int64(completed.sizeBytes)
            guard let upload = BackgroundUploader.upload(of: task, sent: total, expected: total) else { return }
            onEvent(.progress(upload))
            onEvent(.finished(upload, result))
            return
        }
        multipartTaskEnded(id: description.id, part: part, answer: answer)
    }

    /// The end of a multipart upload's task (part 0: its completion), handled on `queue`.
    func multipartTaskEnded(id: String, part: Int, answer: TaskAnswer) {
        queue.async { [self] in
            if part == 0 { completionEnded(id, answer) } else { partEnded(id, part, answer) }
        }
    }

    /// Starts sending `file` to a single upload's one-time URL, and answers the upload.
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

    /// Starts sending `file` to `upload`, and answers the upload. A single upload goes as one PUT, as
    /// `start(file:to:)`. A multipart upload's parts received so far are read first, so starting the
    /// same upload again (after a failure, or one this uploader no longer knows) sends only the parts
    /// still missing; keep the `Upload` for that, it is `Codable`. Its URLs are kept in the app's
    /// Application Support folder until it ends.
    @discardableResult
    public func start(file: URL, upload: Upload, contentType: String? = nil, tag: String? = nil) async throws -> BackgroundUpload {
        guard let plan = upload.multipart else { return try start(file: file, to: upload.uploadURL, contentType: contentType, tag: tag) }
        let layout = try partLayout(plan, fileSize: try fileSize(file))
        let status = try await MultipartCalls(upload: upload, plan: plan, maxRetries: maxRetries, environment: environment).status()
        let received = status.state == "complete" ? Set(1...layout.partCount) : try receivedParts(status, layout: layout)
        let manifest = Manifest(id: UUID().uuidString, tag: tag, file: storedPath(file), upload: upload, received: received.sorted(), attempts: [:], resyncs: 0)
        try save(manifest)
        return queue.sync { [self] in
            let state = MultipartState(manifest: manifest, layout: layout, plan: plan)
            multipart[manifest.id] = state
            schedule(manifest.id)
            return BackgroundUpload(id: manifest.id, tag: tag, progress: UploadProgress(loaded: state.receivedBytes, total: layout.sizeBytes))
        }
    }

    private func tasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    /// The uploads under way, also those started before a relaunch.
    public func uploads() async -> [BackgroundUpload] {
        let single = await tasks().compactMap { task -> BackgroundUpload? in
            guard task.state != .completed, task.state != .canceling else { return nil }
            return BackgroundUploader.upload(of: task, sent: task.countOfBytesSent, expected: task.countOfBytesExpectedToSend)
        }
        let parts = queue.sync {
            multipart.values.map { state in
                BackgroundUpload(id: state.manifest.id, tag: state.manifest.tag, progress: UploadProgress(loaded: state.loaded, total: state.layout.sizeBytes))
            }
        }
        return single + parts
    }

    private func tasks(of id: String) async -> [URLSessionTask] {
        await tasks().filter { BackgroundUploader.description(of: $0)?.id == id }
    }

    private func isMultipart(_ id: String) -> Bool {
        queue.sync { multipart[id] != nil }
    }

    /// Stops sending. A single upload's URL allows one PUT: when the connection ends while paused, the
    /// upload fails and the next try needs a new upload. A multipart upload holds its parts under way
    /// and starts no more until `resume`; a pause ends with the process.
    public func pause(_ id: String) async {
        if isMultipart(id) { queue.sync { multipart[id]?.paused = true } }
        for task in await tasks(of: id) { task.suspend() }
    }

    public func resume(_ id: String) async {
        for task in await tasks(of: id) { task.resume() }
        queue.sync { [self] in
            guard multipart[id] != nil else { return }
            multipart[id]?.paused = false
            schedule(id)
        }
    }

    /// Ends the upload, with `aborted` as its result. A multipart upload is also aborted on the API,
    /// its received parts deleted.
    public func cancel(_ id: String) async {
        let state: MultipartState? = queue.sync { [self] in
            guard let state = multipart.removeValue(forKey: id) else { return nil }
            forget(id)
            return state
        }
        for task in await tasks(of: id) { task.cancel() }
        guard let state else { return }
        await MultipartCalls(upload: state.manifest.upload, plan: state.plan, maxRetries: maxRetries, environment: environment).abort()
        onEvent(.finished(
            BackgroundUpload(id: id, tag: state.manifest.tag, progress: UploadProgress(loaded: state.loaded, total: state.layout.sizeBytes)),
            .failure(sdkError(.aborted, "The upload was aborted."))
        ))
    }

    /// Call this from `application(_:handleEventsForBackgroundURLSession:completionHandler:)` for this
    /// uploader's identifier. The handler is called on the main queue once every event has been told.
    public func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        finishEvents = completionHandler
    }

    /// The system told every event of a background wake. Each was put on `queue` before this, so this
    /// runs after them; the handler is called once the work they started on `queue` is done too.
    func systemFinishedEvents() {
        queue.async { [self] in
            finishRequested = true
            if outstanding == 0 { finishWork() }
        }
    }

    private func startWork() {
        outstanding += 1
    }

    private func endWork() {
        outstanding -= 1
        if outstanding == 0, finishRequested { finishWork() }
    }

    private func finishWork() {
        finishRequested = false
        callFinishEvents()
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

    /// A multipart upload's parts under way and received, for tests.
    func parts(of id: String) -> (inFlight: Set<Int>, received: [Int])? {
        queue.sync { multipart[id].map { ($0.inFlight, $0.manifest.received) } }
    }

    // MARK: Multipart uploads. Everything below runs on `queue`.

    private var manifests: URL { folder.appendingPathComponent("manifests") }
    private var partFiles: URL { folder.appendingPathComponent("parts") }

    private func save(_ manifest: Manifest) throws {
        do {
            try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            // Read when the system wakes the app after a restart, before the device is unlocked again.
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try apiEncoder().encode(manifest).write(to: manifests.appendingPathComponent("\(manifest.id).json"), options: options)
        } catch {
            throw sdkError(.invalidArgument, "The upload's state cannot be written to the app's Application Support folder.")
        }
    }

    /// Removes a multipart upload's files; its state is already gone.
    private func forget(_ id: String) {
        try? FileManager.default.removeItem(at: manifests.appendingPathComponent("\(id).json"))
        let prefix = "\(id)-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: partFiles.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: partFiles.appendingPathComponent(name))
        }
    }

    /// Reads the multipart uploads of an earlier process, before the session exists.
    private static func load(from manifests: URL) -> ([String: MultipartState], [(Manifest, VidexoError)]) {
        var multipart: [String: MultipartState] = [:]
        var broken: [(Manifest, VidexoError)] = []
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: manifests.path) else { return ([:], []) }
        for name in names where name.hasSuffix(".json") {
            let path = manifests.appendingPathComponent(name)
            guard
                let data = try? Data(contentsOf: path),
                let manifest = try? apiDecoder().decode(Manifest.self, from: data),
                let plan = manifest.upload.multipart
            else {
                try? FileManager.default.removeItem(at: path)
                continue
            }
            do {
                let layout = try partLayout(plan, fileSize: fileSize(fileURL(stored: manifest.file)))
                var state = MultipartState(manifest: manifest, layout: layout, plan: plan)
                state.restoring = true
                multipart[manifest.id] = state
            } catch {
                broken.append((manifest, error as? VidexoError ?? sdkError(.invalidArgument, "The file to upload cannot be read.")))
            }
        }
        return (multipart, broken)
    }

    /// The multipart uploads of an earlier process, once the session's tasks are known: those whose tasks
    /// still run go on; the others read their received parts again and send the rest (a force quit, for
    /// one, ends an app's tasks). One whose file is gone or changed ends, its tasks cancelled.
    /// Its work was counted by `init`; everything it reads and changes is on `queue`.
    private func restore() {
        let apply: ([URLSessionTask]) -> Void = { [self] tasks in
            queue.async { [self] in
                defer { endWork() }
                var live: [String: Set<Int>] = [:]
                for task in tasks where task.state == .running || task.state == .suspended {
                    if let description = BackgroundUploader.description(of: task), let part = description.part {
                        live[description.id, default: []].insert(part)
                    }
                }
                for (manifest, error) in broken {
                    for task in tasks where BackgroundUploader.description(of: task)?.id == manifest.id { task.cancel() }
                    forget(manifest.id)
                    onEvent(.finished(BackgroundUpload(id: manifest.id, tag: manifest.tag, progress: UploadProgress(loaded: 0, total: 0)), .failure(error)))
                }
                broken = []
                for (id, var state) in multipart where state.restoring {
                    state.restoring = false
                    state.inFlight = (live[id] ?? []).subtracting(state.endedWhileRestoring)
                    state.endedWhileRestoring = []
                    multipart[id] = state
                    if state.inFlight.isEmpty { resync(id) } else { schedule(id) }
                }
            }
        }
        if let listTasks { listTasks(apply) } else { session.getAllTasks(completionHandler: apply) }
    }

    /// Reads the received parts from the API, then sends the rest.
    private func resync(_ id: String) {
        guard let state = multipart[id] else { return }
        let calls = MultipartCalls(upload: state.manifest.upload, plan: state.plan, maxRetries: maxRetries, environment: environment)
        startWork()
        Task { [self] in
            do {
                let status = try await calls.status()
                queue.async { [self] in
                    defer { endWork() }
                    guard var state = multipart[id] else { return }
                    do {
                        let received = status.state == "complete" ? Set(1...state.layout.partCount) : try receivedParts(status, layout: state.layout)
                        state.manifest.received = received.sorted()
                        try save(state.manifest)
                        multipart[id] = state
                        schedule(id)
                    } catch let error as VidexoError {
                        fail(id, error)
                    } catch {
                        fail(id, sdkError(.invalidResponse, "The upload's parts could not be read."))
                    }
                }
            } catch {
                queue.async { [self] in
                    defer { endWork() }
                    fail(id, error as? VidexoError ?? sdkError(.networkError, "The upload's parts could not be read."))
                }
            }
        }
    }

    /// Starts parts until `partsAtOnce` are under way, or the completion once every part arrived.
    private func schedule(_ id: String) {
        guard let state = multipart[id], !state.paused, !state.restoring else { return }
        let received = Set(state.manifest.received)
        if received.count == state.layout.partCount {
            if state.inFlight.isEmpty { startCompletion(id, after: nil) }
            return
        }
        let missing = (1...state.layout.partCount).filter { !received.contains($0) && !state.inFlight.contains($0) }
        for part in missing.prefix(max(0, partsAtOnce - state.inFlight.count)) {
            startPart(id, part, after: nil)
        }
    }

    private func startPart(_ id: String, _ part: Int, after delay: TimeInterval?) {
        guard let state = multipart[id] else { return }
        let partFile = partFiles.appendingPathComponent("\(id)-\(part)")
        do {
            try FileManager.default.createDirectory(at: partFiles, withIntermediateDirectories: true)
            let digest = try writePart(of: fileURL(stored: state.manifest.file), layout: state.layout, number: part, to: partFile)
            let request = partRequest(try partURL(state.plan, part), digest: digest)
            startTask(id, part, session.uploadTask(with: request, fromFile: partFile), after: delay)
        } catch {
            fail(id, error as? VidexoError ?? sdkError(.invalidArgument, "Part \(part) of the file cannot be read."))
        }
    }

    private func startCompletion(_ id: String, after delay: TimeInterval?) {
        // A background session sends only files: the completion's POST carries an empty one.
        let empty = partFiles.appendingPathComponent("\(id)-complete")
        do {
            try FileManager.default.createDirectory(at: partFiles, withIntermediateDirectories: true)
            try Data().write(to: empty)
        } catch {
            return fail(id, sdkError(.invalidArgument, "The upload's completion cannot be written to the app's Application Support folder."))
        }
        guard let state = multipart[id] else { return }
        startTask(id, 0, session.uploadTask(with: completeRequest(state.plan.completeURL), fromFile: empty), after: delay)
    }

    private func startTask(_ id: String, _ part: Int, _ task: URLSessionUploadTask, after delay: TimeInterval?) {
        guard var state = multipart[id] else { return task.cancel() }
        let description = TaskDescription(id: id, tag: state.manifest.tag, part: part)
        task.taskDescription = (try? JSONEncoder().encode(description)).map { String(decoding: $0, as: UTF8.self) }
        #if !canImport(FoundationNetworking)
        // Only a background session waits for this; the system holds the task, so the wait survives a suspension.
        if let delay, session.configuration.identifier != nil { task.earliestBeginDate = environment.now().addingTimeInterval(delay) }
        #endif
        state.inFlight.insert(part)
        state.sending[part] = nil
        multipart[id] = state
        task.resume()
    }

    private func tellProgress(_ id: String) {
        guard var state = multipart[id] else { return }
        let loaded = state.loaded
        guard loaded > state.reported else { return }
        state.reported = loaded
        multipart[id] = state
        onEvent(.progress(BackgroundUpload(id: id, tag: state.manifest.tag, progress: UploadProgress(loaded: loaded, total: state.layout.sizeBytes))))
    }

    /// Another send of `part` (0: the completion) after `error`, unless its sends are used up. While the
    /// upload is paused it waits: `resume` starts what is missing again.
    private func again(_ id: String, _ part: Int, after delay: TimeInterval?, _ error: VidexoError, budget key: Int? = nil, of limit: Int? = nil) {
        guard var state = multipart[id] else { return }
        let key = key ?? part
        let used = state.manifest.attempts[key] ?? 0
        guard used < (limit ?? maxRetries) else { return fail(id, error) }
        state.manifest.attempts[key] = used + 1
        multipart[id] = state
        do {
            try save(state.manifest)
        } catch {
            return fail(id, error as? VidexoError ?? sdkError(.invalidArgument, "The upload's state cannot be written."))
        }
        guard !state.paused, !state.restoring else { return }
        let wait = delay ?? backoffSeconds(attempt: used, random: environment.random())
        if part == 0 { startCompletion(id, after: wait) } else { startPart(id, part, after: wait) }
    }

    private func partEnded(_ id: String, _ part: Int, _ answer: TaskAnswer) {
        // An old task's end: the upload was cancelled, failed or finished, or the part already arrived.
        guard var state = multipart[id], state.inFlight.contains(part) || state.restoring else { return }
        if state.restoring { state.endedWhileRestoring.insert(part) }
        state.inFlight.remove(part)
        state.sending[part] = nil
        multipart[id] = state
        switch partOutcome(answer, now: environment.now()) {
        case .received:
            try? FileManager.default.removeItem(at: partFiles.appendingPathComponent("\(id)-\(part)"))
            if !state.manifest.received.contains(part) { state.manifest.received.append(part) }
            state.manifest.attempts[part] = nil
            multipart[id] = state
            do {
                try save(state.manifest)
            } catch {
                return fail(id, error as? VidexoError ?? sdkError(.invalidArgument, "The upload's state cannot be written."))
            }
            tellProgress(id)
            schedule(id)
        case let .again(after, error):
            again(id, part, after: after, error)
        case let .failed(error) where error.code == .aborted:
            // A cancellation this uploader did not ask for (`cancel` forgets the upload first): the system's.
            again(id, part, after: nil, error)
        case let .failed(error):
            fail(id, error)
        }
    }

    private func completionEnded(_ id: String, _ answer: TaskAnswer) {
        guard var state = multipart[id], state.inFlight.contains(0) || state.restoring else { return }
        if state.restoring { state.endedWhileRestoring.insert(0) }
        state.inFlight.remove(0)
        multipart[id] = state
        if answer.failure == nil, let status = answer.status, (200..<300).contains(status) {
            guard let completed = try? apiDecoder().decode(CompletedUpload.self, from: answer.body) else {
                return fail(id, sdkError(.invalidResponse, "The upload URL answered without the completed upload.", status: status, body: answer.body))
            }
            return succeed(id, completed)
        }
        if let error = answer.error {
            // The API found a part replaced by a request that crashed and freed the parts: read them again, once.
            if error.reason == "upload_incomplete", state.manifest.resyncs < 1 {
                state.manifest.resyncs += 1
                multipart[id] = state
                return resync(id)
            }
            // Another completion of the same upload is running (one whose connection was lost, say): completing
            // again reads its end, the completed upload once it is done, within `completionWaits` tries of their own.
            if error.reason == "upload_used" {
                return again(id, 0, after: partInFlightWait, error, budget: -1, of: completionWaits)
            }
        }
        switch partOutcome(answer, now: environment.now()) {
        case let .again(after, error):
            again(id, 0, after: after, error)
        case let .failed(error) where error.code == .aborted:
            again(id, 0, after: nil, error)
        case let .failed(error):
            fail(id, error)
        case .received:
            fail(id, sdkError(.invalidResponse, "The upload URL answered without the completed upload."))
        }
    }

    private func succeed(_ id: String, _ completed: CompletedUpload) {
        guard let state = multipart.removeValue(forKey: id) else { return }
        forget(id)
        let total = state.layout.sizeBytes
        let upload = BackgroundUpload(id: id, tag: state.manifest.tag, progress: UploadProgress(loaded: total, total: total))
        onEvent(.progress(upload))
        onEvent(.finished(upload, .success(completed)))
    }

    /// Ends the upload with `error`. The upload stays on the API, so starting it again resumes it.
    private func fail(_ id: String, _ error: VidexoError) {
        guard let state = multipart.removeValue(forKey: id) else { return }
        forget(id)
        // Counted, so the system's completion handler of a wake comes after the other tasks are cancelled.
        startWork()
        session.getAllTasks { [self] tasks in
            for task in tasks where BackgroundUploader.description(of: task)?.id == id { task.cancel() }
            queue.async { [self] in endWork() }
        }
        onEvent(.finished(
            BackgroundUpload(id: id, tag: state.manifest.tag, progress: UploadProgress(loaded: state.loaded, total: state.layout.sizeBytes)),
            .failure(error)
        ))
    }
}

/// The system's completion handler on its way to the main queue.
private struct MainQueueHandler: @unchecked Sendable {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}
