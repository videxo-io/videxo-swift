import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The client of `/v1/client/*` for an app, which holds a short-lived client token, never an API key
// (https://videxo.io/docs/client-tokens). Jobs are created by your backend with its key; a token only
// creates uploads and reads the jobs it was given.

private let clientTokenPrefix = "vdx_ct_"
/// Refresh a token this close to its expiry, before the request would be refused.
private let refreshBeforeExpiry: TimeInterval = 30
/// The refusals a new token of the chain answers.
private let refreshableReasons: Set<String> = ["client_token_expired", "client_token_superseded"]

/// What your backend answers when asked for a new token: `token`, and its `id` as your backend got it.
public struct FreshToken: Sendable, CustomStringConvertible {
    public let token: String
    public let id: String?

    public init(token: String, id: String? = nil) {
        self.token = token
        self.id = id
    }

    /// Without the token, so a log line cannot hold it.
    public var description: String { "FreshToken(id: \(id ?? "nil"))" }
}

/// A value that must be a client token: an API key in an app is a published key, so it stops here.
/// The messages do not repeat the value: it may be a real key.
func checkedToken(_ value: String) throws -> String {
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let letters = token.dropFirst(4)
    if token.hasPrefix("vdx_"), letters.count == 64, letters.allSatisfy({ $0.isASCII && $0.isLetter }) {
        throw sdkError(
            .invalidArgument,
            "VidexoClient takes a client token, never an API key. Keep the API key on your server and mint client tokens there."
        )
    }
    let printable = token.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    guard token.hasPrefix(clientTokenPrefix), printable else {
        throw sdkError(.invalidArgument, "VidexoClient needs a client token (vdx_ct_...) your server minted with POST /v1/client-tokens.")
    }
    return token
}

/// The client of `/v1/client/*` for an app.
///
/// ```swift
/// let videxo = try VidexoClient(token: minted.token, tokenId: minted.id) { request in
///     try await myBackend.refresh(tokenId: request.tokenId)
/// }
/// let upload = try await videxo.uploads.upload(file: url) { progress in show(progress.fraction) }
/// ```
public actor VidexoClient {
    /// What `getToken` is asked: a continuation of this token (`continues`).
    public struct TokenRequest: Sendable {
        /// The current token's id, once known.
        public let tokenId: String?
    }

    public typealias GetToken = @Sendable (TokenRequest) async throws -> FreshToken

    public static let defaultBaseURL = URL(string: "https://api.videxo.io")!

    public nonisolated let baseURL: URL
    public nonisolated var uploads: ClientUploads { ClientUploads(client: self) }
    public nonisolated var jobs: ClientJobs { ClientJobs(client: self) }

    private nonisolated let base: String
    private let getToken: GetToken?
    private let transport: any VidexoTransport
    private let maxRetries: Int
    private let timeout: TimeInterval?
    nonisolated let environment: SDKEnvironment

    private var currentToken: String
    /// Every token of this client: a request under way when its token was replaced can still fail with it.
    private var tokens: Set<String>
    private var currentTokenId: String?
    private var expiresAt: Date?
    private var read = false
    private var refreshed = false
    private var clockAhead = false
    private var refreshing: Task<Void, Error>?

    /// - Parameters:
    ///   - token: A client token your backend minted (`vdx_ct_...`), never an API key.
    ///   - tokenId: The token's id. Without it the id is read from `GET /v1/client/token` on first use.
    ///   - baseURL: The API's address.
    ///   - transport: What sends the calls; `URLSession.shared` by default.
    ///   - maxRetries: Retries of a failed call.
    ///   - timeout: Seconds one attempt may take; nil for none.
    ///   - getToken: Asks your backend for a continuation of the token, when it is about to expire or
    ///     is refused as expired or superseded, so long flows keep their uploads and jobs. A failed
    ///     refresh is asked again with the same id on the next call. A continuation keeps read job ids
    ///     by itself; for a token that only uploads, your backend names its `uploads` section again.
    public init(
        token: String,
        tokenId: String? = nil,
        baseURL: URL = VidexoClient.defaultBaseURL,
        transport: any VidexoTransport = URLSessionTransport(),
        maxRetries: Int = 2,
        timeout: TimeInterval? = 60,
        getToken: GetToken? = nil
    ) throws {
        try self.init(
            token: token,
            tokenId: tokenId,
            baseURL: baseURL,
            transport: transport,
            maxRetries: maxRetries,
            timeout: timeout,
            environment: SDKEnvironment(),
            getToken: getToken
        )
    }

    init(
        token: String,
        tokenId: String?,
        baseURL: URL,
        transport: any VidexoTransport,
        maxRetries: Int,
        timeout: TimeInterval?,
        environment: SDKEnvironment,
        getToken: GetToken?
    ) throws {
        let checked = try checkedToken(token)
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw sdkError(.invalidArgument, "baseURL must be an http or https URL.")
        }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        self.base = base
        self.baseURL = URL(string: base) ?? baseURL
        currentToken = checked
        tokens = [checked]
        currentTokenId = tokenId
        self.getToken = getToken
        self.transport = transport
        self.maxRetries = max(0, maxRetries)
        self.timeout = timeout
        self.environment = environment
    }

    /// `GET /v1/client/token`: the token's id, chain and expiry, the uploads used and the jobs it may read.
    public func token() async throws -> ClientTokenInfo {
        try await request(Call(method: "GET", path: "/v1/client/token", remember: true))
    }

    /// The id of the current token, once known.
    public var tokenId: String? { currentTokenId }

    struct Call: Sendable {
        var method: String
        var path: String
        var body: Data?
        var headers: [String: String] = [:]
        var remember = false
    }

    /// What a read of the token `used` answered, unless the token was replaced while it was on its way.
    private func remember(_ info: ClientTokenInfo, used: String) {
        guard used == currentToken else { return }
        currentTokenId = info.id
        expiresAt = info.expiresAt
        read = true
        // A token just refreshed cannot be about to end, so this device's clock runs ahead. Asking for a
        // new one before every call would not help: from here on only the API's own refusal starts a refresh.
        if refreshed, info.expiresAt.timeIntervalSince(environment.now()) < refreshBeforeExpiry { clockAhead = true }
        refreshed = false
    }

    /// The current token is replaced by what `getToken` answers; concurrent calls share one refresh.
    /// Its task outlives a call that gives up on it, for the calls still waiting.
    private func refresh(_ getToken: @escaping GetToken) -> Task<Void, Error> {
        if let refreshing { return refreshing }
        let request = TokenRequest(tokenId: currentTokenId)
        let task = Task {
            defer { refreshing = nil }
            let fresh = try await getToken(request)
            let token = try checkedToken(fresh.token)
            // The old id stays until the new one is known, so a failed refresh asks with the same id.
            currentToken = token
            tokens.insert(token)
            if let id = fresh.id { currentTokenId = id }
            expiresAt = nil
            read = false
            refreshed = true
        }
        refreshing = task
        return task
    }

    /// After `used` was refused as ended: a refresh, unless another call already replaced that token. A
    /// refusal that arrives late must not mint a third token, whose first use would end the second while
    /// a call with it is under way.
    private func replace(_ used: String, _ getToken: @escaping GetToken) async throws {
        if let refreshing { try await settled(refreshing) }
        if currentToken == used { try await settled(refresh(getToken)) }
    }

    /// Before a call: learns the token's id and expiry while it still works, and refreshes it when it is about to end.
    private func prepare(_ call: Call) async throws {
        guard let getToken else { return }
        if let refreshing { try await settled(refreshing) }
        if !read, call.path != "/v1/client/token" {
            let used = currentToken
            let answer = try await send(Call(method: "GET", path: "/v1/client/token"))
            if answer.isOK {
                if let info = try? apiDecoder().decode(ClientTokenInfo.self, from: answer.body) { remember(info, used: used) }
            } else if refreshable(answer) {
                return try await replace(used, getToken)
            }
            // Any other refusal is left to the call itself, which answers it.
        }
        if !clockAhead, let expiresAt, expiresAt.timeIntervalSince(environment.now()) < refreshBeforeExpiry {
            try await settled(refresh(getToken))
        }
    }

    private func send(_ call: Call) async throws -> HTTPAnswer {
        guard let url = URL(string: base + call.path) else {
            throw sdkError(.invalidArgument, "The request's address is not a URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = call.method
        request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        if let body = call.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in call.headers { request.setValue(value, forHTTPHeaderField: name) }
        let known = tokens
        return try await sendWithRetries(
            transport,
            request,
            maxRetries: maxRetries,
            timeout: timeout,
            environment: environment,
            redact: { text in known.reduce(text) { $0.replacingOccurrences(of: $1, with: "[client token]") } }
        )
    }

    /// One call: a token that is about to end is refreshed first, one refused as ended is refreshed and
    /// the call sent again once.
    func request<T: Decodable>(_ call: Call) async throws -> T {
        try await prepare(call)
        var used = currentToken
        var answer = try await send(call)
        if let getToken, refreshable(answer) {
            try await replace(used, getToken)
            used = currentToken
            answer = try await send(call)
        }
        guard answer.isOK else { throw errorFromResponse(status: answer.status, headers: answer.headers, body: answer.body) }
        let value: T
        do {
            value = try apiDecoder().decode(T.self, from: answer.body)
        } catch {
            throw sdkError(.invalidResponse, "The API answered with a body the SDK could not read.", status: answer.status, body: answer.body)
        }
        if call.remember, let info = value as? ClientTokenInfo { remember(info, used: used) }
        return value
    }

    private func refreshable(_ answer: HTTPAnswer) -> Bool {
        answer.status == 401 && refreshableReasons.contains(reason(of: answer) ?? "")
    }

    private func reason(of answer: HTTPAnswer) -> String? {
        struct Reason: Decodable { let reason: String? }
        return (try? JSONDecoder().decode(Reason.self, from: answer.body))?.reason
    }
}

/// Waits for the shared refresh as long as this call still wants it: cancelling the calling task ends
/// this call's wait and nothing else, so the refresh goes on for the calls still waiting.
private func settled(_ refresh: Task<Void, Error>) async throws {
    let waiter = RefreshWaiter()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.set(continuation)
            Task {
                do {
                    try await refresh.value
                    waiter.finish(nil)
                } catch {
                    waiter.finish(error)
                }
            }
        }
    } onCancel: {
        waiter.finish(sdkError(.aborted, "The request was aborted while its token was refreshed."))
    }
}

/// A continuation resumed once, by the refresh or by the cancellation, whichever comes first.
private final class RefreshWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished: Error??

    func set(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let finished {
            resume(continuation, finished)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard finished == nil else { return }
        finished = .some(error)
        if let continuation { resume(continuation, error) }
        continuation = nil
    }

    private func resume(_ continuation: CheckedContinuation<Void, Error>, _ error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

/// The uploads of a client token.
public struct ClientUploads: Sendable {
    let client: VidexoClient

    /// `POST /v1/client/uploads`: an upload within the token's grant. It sends an Idempotency-Key of
    /// its own, kept for its retries and a refresh, so a lost answer spends nothing.
    /// - Parameters:
    ///   - filename: A plain name: letters, digits, dots, underscores and hyphens, starting with a letter or digit.
    ///   - sizeBytes: The exact byte length.
    ///   - multipart: Whether the file goes in parts that resume after a lost connection; needed past
    ///     100 MB, up to the plan's input limit and the token's `max_size_bytes`.
    ///   - partSizeBytes: With `multipart`: every part's size but the last's, 5 MiB to 64 MiB; the API's
    ///     8 MiB when nil.
    public func create(
        filename: String,
        sizeBytes: Int,
        contentType: String = "application/octet-stream",
        multipart: Bool = false,
        partSizeBytes: Int? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Upload {
        struct Body: Encodable {
            let filename: String
            let size_bytes: Int
            let content_type: String
            let multipart: Bool?
            let part_size_bytes: Int?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(Body(
            filename: filename,
            size_bytes: sizeBytes,
            content_type: contentType,
            multipart: multipart ? true : nil,
            part_size_bytes: multipart ? partSizeBytes : nil
        ))
        let key = idempotencyKey ?? client.environment.uuid()
        return try await client.request(VidexoClient.Call(method: "POST", path: "/v1/client/uploads", body: body, headers: ["Idempotency-Key": key]))
    }

    /// `create` for a file: its size, a plain form of its name, and its content type by its extension,
    /// unless you name them; multipart for a file past 100 MB unless you say. Send the bytes with
    /// `VidexoUpload` or `BackgroundUploader`.
    public func create(
        forFile file: URL,
        filename: String? = nil,
        contentType: String? = nil,
        multipart: Bool? = nil,
        partSizeBytes: Int? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Upload {
        let size = try fileSize(file)
        return try await create(
            filename: filename ?? plainFilename(file.lastPathComponent),
            sizeBytes: Int(size),
            contentType: contentType ?? contentTypeOf(file),
            multipart: multipart ?? (size > singleUploadMaxBytes),
            partSizeBytes: partSizeBytes,
            idempotencyKey: idempotencyKey
        )
    }

    /// Creates an upload and sends the file; answers the completed upload. Hand its `inputURL` to your
    /// backend, which creates the job with its API key.
    ///
    /// A file past 100 MB, or any with `multipart: true`, goes as a multipart upload: three parts at a
    /// time, each sent again after a lost connection, then completed; cancelling the calling task aborts
    /// it. To resume one that failed, keep the `Upload` from `create` and pass it to
    /// `VidexoUpload().send(file:upload:)`. A smaller file goes as one PUT, never retried: call this again
    /// for a new upload, within the token's `max_count`.
    public func upload(
        file: URL,
        filename: String? = nil,
        contentType: String? = nil,
        multipart: Bool? = nil,
        partSizeBytes: Int? = nil,
        idempotencyKey: String? = nil,
        uploadTimeout: TimeInterval? = nil,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> CompletedUpload {
        let type = contentType ?? contentTypeOf(file)
        let upload = try await create(
            forFile: file,
            filename: filename,
            contentType: type,
            multipart: multipart,
            partSizeBytes: partSizeBytes,
            idempotencyKey: idempotencyKey
        )
        return try await VidexoUpload().send(file: file, upload: upload, contentType: type, timeout: uploadTimeout, onProgress: onProgress)
    }
}

/// The jobs a client token may read.
public struct ClientJobs: Sendable {
    let client: VidexoClient

    /// `GET /v1/client/jobs/{id}`: a job the token may read. Any other job is `not_found`.
    public func get(_ id: String) async throws -> ClientJob {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let path = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return try await client.request(VidexoClient.Call(method: "GET", path: "/v1/client/jobs/\(path)"))
    }

    /// `GET /v1/client/jobs`: the jobs the token may read, newest first.
    public func list() async throws -> [ClientJob] {
        let list: ClientJobList = try await client.request(VidexoClient.Call(method: "GET", path: "/v1/client/jobs"))
        return list.data
    }

    /// Reads the job until it is `succeeded`, `failed` or `cancelled`, and answers it (a failed job is
    /// answered, not thrown). Waits out a 429 by its `Retry-After`. Throws `wait_timeout` when the job
    /// has not ended within `timeout`, `aborted` when the calling task is cancelled.
    public func wait(_ id: String, timeout: TimeInterval = 600, interval: TimeInterval = 2) async throws -> ClientJob {
        let sleep = client.environment.sleep
        do {
            return try await withThrowingTaskGroup(of: ClientJob.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    while true {
                        var pause = interval
                        do {
                            let job = try await get(id)
                            if job.state.isFinal { return job }
                        } catch let error as VidexoError where error.status == 429 {
                            pause = max(interval, TimeInterval(error.retryAfter ?? 0))
                        }
                        try await sleep(pause)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw sdkError(.waitTimeout, "Job \(id) did not end within \(Int(timeout)) s.")
                }
                guard let job = try await group.next() else { throw CancellationError() }
                return job
            }
        } catch is CancellationError {
            throw sdkError(.aborted, "The wait for job \(id) was aborted.")
        }
    }
}
