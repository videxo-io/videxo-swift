import Foundation
import XCTest
@testable import Videxo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The multipart routes of one upload, as the API answers them, on a real socket. Parts are kept by
/// number; `script` answers a part's PUT instead, once per entry, before the part is kept.
final class FakeMultipartAPI: @unchecked Sendable {
    let size: Int
    let partSize: Int
    private let lock = NSLock()
    /// The parts the upload lists; a completion joins them, and the list empties.
    private var parts: [Int: Data] = [:]
    /// Every part that arrived, also after the completion.
    private var stored: [Int: Data] = [:]
    private var script: [Int: [LocalServer.Reply]] = [:]
    private var completeScript: [LocalServer.Reply] = []
    /// States the next reads of the upload answer, as when another completion is running.
    private var stateScript: [String] = []
    private(set) var completed = false
    private(set) var deleted = false
    /// A part listed with another size than the file's, for the refusal test.
    var listedSizeOverride: [Int: Int] = [:]
    var server: LocalServer!

    init(size: Int, partSize: Int, received: [Int: Data] = [:]) throws {
        self.size = size
        self.partSize = partSize
        parts = received
        stored = received
        server = try LocalServer { [unowned self] request in self.answer(request) }
    }

    var partCount: Int { (size + partSize - 1) / partSize }

    func script(part: Int, _ replies: [LocalServer.Reply]) {
        lock.lock()
        defer { lock.unlock() }
        script[part, default: []] += replies
    }

    func scriptStates(_ states: [String]) {
        lock.lock()
        defer { lock.unlock() }
        stateScript += states
    }

    func scriptCompletion(_ replies: [LocalServer.Reply]) {
        lock.lock()
        defer { lock.unlock() }
        completeScript += replies
    }

    var received: [Int: Data] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var joined: Data {
        let parts = received
        return (1...partCount).reduce(into: Data()) { $0.append(parts[$1] ?? Data()) }
    }

    /// The method and path of every request, in order.
    var calls: [String] {
        server.requests.map { request in
            let words = request.requestLine.split(separator: " ")
            let path = words[1].split(separator: "?")[0]
            return "\(words[0]) \(path)"
        }
    }

    func partPuts(_ number: Int) -> [LocalServer.Received] {
        server.requests.filter { $0.requestLine.hasPrefix("PUT /v1/uploads/up_1/parts/\(number)?") }
    }

    var query: String { "account=acc_1&expires=1900000000&signature=secret-signature" }
    var root: String { "http://127.0.0.1:\(server.port)/v1/uploads/up_1" }

    func upload(partSize plannedSize: Int? = nil, partCount plannedCount: Int? = nil, partsAt host: String? = nil) -> Upload {
        let partRoot = host.map { "http://\($0)/v1/uploads/up_1" } ?? root
        let json = """
        {"id":"up_1","input_url":"videxo://uploads/up_1","upload_url":"\(root)?\(query)",\
        "upload_url_expires_at":"2026-11-08T18:00:00.000Z","expires_at":"2026-11-09T12:00:00.000Z","max_size_bytes":\(size),\
        "multipart":{"part_size_bytes":\(plannedSize ?? partSize),"part_count":\(plannedCount ?? partCount),\
        "part_url_template":"\(partRoot)/parts/{part_number}?\(query)","complete_url":"\(root)/complete?\(query)"}}
        """
        return try! Upload(json: Data(json.utf8))
    }

    private func length(of part: Int) -> Int { min(partSize, size - (part - 1) * partSize) }

    private func answer(_ request: LocalServer.Received) -> LocalServer.Reply {
        let words = request.requestLine.split(separator: " ")
        let method = String(words[0])
        let path = String(words[1].split(separator: "?")[0])
        lock.lock()
        defer { lock.unlock() }
        if method == "GET", path == "/v1/uploads/up_1" {
            let listed = parts.keys.sorted().map { number in
                #"{"part_number":\#(number),"size_bytes":\#(listedSizeOverride[number] ?? parts[number]!.count),"sha256":"abc"}"#
            }
            let state = stateScript.isEmpty ? (completed ? "complete" : "pending") : stateScript.removeFirst()
            return .answer(status: 200, body: """
            {"id":"up_1","state":"\(state)","size_bytes":\(size),"part_size_bytes":\(partSize),"part_count":\(partCount),\
            "parts":[\(completed ? "" : listed.joined(separator: ","))],"input_url":"videxo://uploads/up_1",\
            "upload_url_expires_at":"2026-11-08T18:00:00.000Z","expires_at":"2026-11-09T12:00:00.000Z"}
            """)
        }
        if method == "PUT", path.hasPrefix("/v1/uploads/up_1/parts/"), let number = Int(path.split(separator: "/").last ?? "") {
            if var replies = script[number], !replies.isEmpty {
                let reply = replies.removeFirst()
                script[number] = replies
                // An answer lost after the part arrived: the part is kept, and the next send hears part_received.
                if case .answer(409, let body, _) = reply, body.contains("part_received") {
                    parts[number] = request.body
                    stored[number] = request.body
                }
                return reply
            }
            guard request.body.count == length(of: number) else {
                return .answer(status: 400, body: problem("invalid_request", status: 400, reason: "size_mismatch"))
            }
            if parts[number] != nil { return .answer(status: 409, body: problem("conflict", status: 409, reason: "part_received")) }
            parts[number] = request.body
            stored[number] = request.body
            return .answer(status: 200, body: #"{"part_number":\#(number),"size_bytes":\#(request.body.count),"sha256":"abc"}"#)
        }
        if method == "POST", path == "/v1/uploads/up_1/complete" {
            if !completeScript.isEmpty { return completeScript.removeFirst() }
            guard parts.count == partCount || completed else {
                return .answer(status: 409, body: problem("conflict", status: 409, reason: "upload_incomplete"))
            }
            completed = true
            parts = [:]
            return .answer(status: 200, body: #"{"id":"up_1","input_url":"videxo://uploads/up_1","size_bytes":\#(size),"sha256":null,"content_type":"video/mp4","expires_at":"2026-11-09T12:00:00.000Z"}"#)
        }
        if method == "DELETE", path == "/v1/uploads/up_1" {
            deleted = true
            return .answer(status: 200, body: #"{"id":"up_1","deleted":true}"#)
        }
        return .answer(status: 404, body: problem("not_found", status: 404))
    }
}

/// A file whose every byte tells its place, so a part from the wrong range shows.
func patternedFile(_ bytes: Int) throws -> (URL, Data) {
    let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("clip.mp4")
    try data.write(to: file)
    return (file, data)
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UploadProgress] = []

    func add(_ value: UploadProgress) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var all: [UploadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class MultipartTests: XCTestCase {
    func testSendsEachPartFromItsRangeAndCompletes() async throws {
        let (file, data) = try patternedFile(250_000)
        let api = try FakeMultipartAPI(size: 250_000, partSize: 100_000)
        defer { api.server.stop() }
        let progress = Progress()
        let completed = try await VidexoUpload().send(file: file, upload: api.upload()) { progress.add($0) }
        XCTAssertEqual(completed.inputURL, "videxo://uploads/up_1")
        XCTAssertNil(completed.sha256, "a multipart upload has no whole-file hash")
        XCTAssertEqual(api.joined, data)
        XCTAssertEqual(api.calls.first, "GET /v1/uploads/up_1", "the received parts are read first")
        XCTAssertEqual(api.calls.last, "POST /v1/uploads/up_1/complete")
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("PUT") }.count, 3)
        XCTAssertEqual(progress.all.last, UploadProgress(loaded: 250_000, total: 250_000))
        let loaded = progress.all.map(\.loaded)
        XCTAssertEqual(loaded, loaded.sorted(), "progress never goes back")
        for request in api.server.requests where request.requestLine.hasPrefix("PUT") {
            XCTAssertNil(request.headers["authorization"], "the part URL needs no credential")
            XCTAssertEqual(request.headers["content-type"], "application/octet-stream")
            #if canImport(CryptoKit)
            let digest = Data(SHA256.hash(data: request.body)).base64EncodedString()
            XCTAssertEqual(request.headers["content-digest"], "sha-256=:\(digest):")
            #endif
        }
    }

    func testResumesWithOnlyTheMissingParts() async throws {
        let (file, data) = try patternedFile(400_000)
        let api = try FakeMultipartAPI(
            size: 400_000,
            partSize: 100_000,
            received: [1: data[0..<100_000], 3: data[200_000..<300_000]]
        )
        defer { api.server.stop() }
        let progress = Progress()
        _ = try await VidexoUpload().send(file: file, upload: api.upload()) { progress.add($0) }
        XCTAssertEqual(api.partPuts(1).count, 0)
        XCTAssertEqual(api.partPuts(3).count, 0)
        XCTAssertEqual(api.partPuts(2).count, 1)
        XCTAssertEqual(api.partPuts(4).count, 1)
        XCTAssertEqual(api.joined, data)
        XCTAssertEqual(progress.all.first?.loaded, 200_000, "the parts received before count from the start")
    }

    func testAPartRefusedWithA4xxIsNotSentAgainAndTheUploadIsNotCompleted() async throws {
        let (file, _) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        api.script(part: 2, [.answer(status: 403, body: problem("permission_denied", status: 403, reason: "link_invalid"))])
        await assertThrowsVidexo(.permissionDenied, reason: "link_invalid") {
            _ = try await VidexoUpload().send(file: file, upload: api.upload(), partsAtOnce: 1)
        }
        XCTAssertEqual(api.partPuts(2).count, 1)
        XCTAssertFalse(api.calls.contains("POST /v1/uploads/up_1/complete"))
        XCTAssertFalse(api.deleted, "a failure keeps the upload, so it can be resumed")
    }

    func testAPartThatKeepsAnswering429IsGivenUpAfterItsRetries() async throws {
        let (file, _) = try patternedFile(100_000)
        let api = try FakeMultipartAPI(size: 100_000, partSize: 100_000)
        defer { api.server.stop() }
        let busy = LocalServer.Reply.answer(status: 429, body: problem("rate_limited", status: 429, reason: "parts_in_flight"), headers: ["Retry-After": "0"])
        api.script(part: 1, Array(repeating: busy, count: 10))
        await assertThrowsVidexo(.rateLimited, reason: "parts_in_flight") {
            _ = try await VidexoUpload().send(file: file, upload: api.upload(), maxRetries: 2)
        }
        XCTAssertEqual(api.partPuts(1).count, 3, "the first send and two more")
    }

    func testAPartIsSentAgainAfterA503AndAnAnswerLostAfterItArrived() async throws {
        let (file, data) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000, received: [:])
        defer { api.server.stop() }
        api.script(part: 1, [.answer(status: 503, body: problem("service_unavailable", status: 503, reason: "temporary"), headers: ["Retry-After": "0"])])
        // The part arrived, but its answer was lost: the next send is told part_received, which is done.
        api.script(part: 2, [.answer(status: 409, body: problem("conflict", status: 409, reason: "part_received"))])
        _ = try await VidexoUpload().send(file: file, upload: api.upload(), partsAtOnce: 1)
        XCTAssertEqual(api.partPuts(1).count, 2)
        XCTAssertEqual(api.partPuts(2).count, 1)
        XCTAssertEqual(api.received[1], data[0..<100_000])
    }

    func testRefusesAPlanItCannotUseBeforeSendingAnything() async throws {
        let (file, _) = try patternedFile(250_000)
        let api = try FakeMultipartAPI(size: 250_000, partSize: 100_000)
        defer { api.server.stop() }
        await assertThrowsVidexo(.invalidResponse) {
            _ = try await VidexoUpload().send(file: file, upload: api.upload(partSize: 0, partCount: 3))
        }
        await assertThrowsVidexo(.invalidArgument) {
            // Two parts of 100,000 bytes cannot hold this file.
            _ = try await VidexoUpload().send(file: file, upload: api.upload(partCount: 2))
        }
        XCTAssertEqual(api.server.requests.count, 0)
    }

    func testRefusesAResumeWhereAListedPartHasAnotherSize() async throws {
        let (file, data) = try patternedFile(300_000)
        let api = try FakeMultipartAPI(size: 300_000, partSize: 100_000, received: [2: data[100_000..<200_000]])
        defer { api.server.stop() }
        api.listedSizeOverride = [2: 99_999]
        await assertThrowsVidexo(.invalidResponse) {
            _ = try await VidexoUpload().send(file: file, upload: api.upload())
        }
        XCTAssertEqual(api.calls, ["GET /v1/uploads/up_1"], "no part is sent against a listing that does not fit the file")
    }

    func testRefusesAFileOfAnotherSizeThanTheUploadDeclared() async throws {
        let (file, _) = try patternedFile(240_000)
        let api = try FakeMultipartAPI(size: 250_000, partSize: 100_000)
        defer { api.server.stop() }
        await assertThrowsVidexo(.invalidArgument) {
            _ = try await VidexoUpload().send(file: file, upload: api.upload())
        }
        XCTAssertFalse(api.calls.contains { $0.hasPrefix("PUT") })
    }

    func testCancellingAbortsTheUpload() async throws {
        let (file, _) = try patternedFile(300_000)
        let api = try FakeMultipartAPI(size: 300_000, partSize: 100_000)
        defer { api.server.stop() }
        // The parts go to an address that never answers, so the upload is under way when it is cancelled.
        let handle = try VidexoUpload().start(file: file, upload: api.upload(partsAt: "10.255.255.1:9"))
        try await Task.sleep(nanoseconds: 300_000_000)
        handle.cancel()
        await assertThrowsVidexo(.aborted) { _ = try await handle.value }
        XCTAssertTrue(api.deleted, "a cancelled multipart upload is aborted on the API")
        XCTAssertEqual(api.calls.last, "DELETE /v1/uploads/up_1")
    }

    func testCompletingAnUploadThatIsAlreadyCompleteAnswersIt() async throws {
        let (file, _) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        _ = try await VidexoUpload().send(file: file, upload: api.upload())
        // Sent again, as after a lost answer of the completion: the state says complete, and only the completion repeats.
        let again = try await VidexoUpload().send(file: file, upload: api.upload())
        XCTAssertEqual(again.id, "up_1")
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("PUT") }.count, 2)
    }

    func testAFirstPartRefusedForGoodStopsTheOtherParts() async throws {
        let (file, _) = try patternedFile(500_000)
        let api = try FakeMultipartAPI(size: 500_000, partSize: 100_000)
        defer { api.server.stop() }
        api.script(part: 1, [.answer(status: 403, body: problem("permission_denied", status: 403, reason: "link_invalid"))])
        api.script(part: 2, [.after(1, .answer(status: 200, body: #"{"part_number":2,"size_bytes":100000,"sha256":"abc"}"#))])
        await assertThrowsVidexo(.permissionDenied, reason: "link_invalid") {
            _ = try await VidexoUpload().send(file: file, upload: api.upload(), partsAtOnce: 2)
        }
        for part in 3...5 { XCTAssertEqual(api.partPuts(part).count, 0, "part \(part) is not sent after part 1 was refused") }
        XCTAssertFalse(api.calls.contains("POST /v1/uploads/up_1/complete"))
    }

    /// A completion whose connection was lost still runs on the API: the next one is refused with
    /// upload_used, reads the state until that one ends, and completes.
    func testACompletionAlreadyRunningIsWaitedFor() async throws {
        let (file, _) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        api.scriptCompletion([.answer(status: 409, body: problem("conflict", status: 409, reason: "upload_used"))])
        // The first read is the one before the parts; then the running completion, then its failure back to pending.
        api.scriptStates(["pending", "uploading", "pending"])
        let sleeps = Sleeps()
        let transfer = try MultipartTransfer(
            file: file, upload: api.upload(), partsAtOnce: 1, maxRetries: 0, timeout: nil, environment: environment(sleeps: sleeps), onProgress: nil
        )
        let completed = try await transfer.run()
        XCTAssertEqual(completed.id, "up_1")
        XCTAssertEqual(api.calls.filter { $0 == "POST /v1/uploads/up_1/complete" }.count, 2)
        XCTAssertEqual(api.calls.filter { $0 == "GET /v1/uploads/up_1" }.count, 3)
        XCTAssertEqual(sleeps.all, [5, 5])
    }

    func testACompletionThatStaysUsedIsGivenUp() async throws {
        let (file, _) = try patternedFile(100_000)
        let api = try FakeMultipartAPI(size: 100_000, partSize: 100_000)
        defer { api.server.stop() }
        api.scriptCompletion([.answer(status: 409, body: problem("conflict", status: 409, reason: "upload_used"))])
        api.scriptStates(["pending"] + Array(repeating: "uploading", count: 40))
        let sleeps = Sleeps()
        let transfer = try MultipartTransfer(
            file: file, upload: api.upload(), partsAtOnce: 1, maxRetries: 0, timeout: nil, environment: environment(sleeps: sleeps), onProgress: nil
        )
        await assertThrowsVidexo(.conflict, reason: "upload_used") { _ = try await transfer.run() }
        XCTAssertEqual(sleeps.all.count, completionWaits)
        XCTAssertFalse(api.deleted)
    }

    func testTheUploadIsCodableTheAPIsWay() throws {
        let api = try FakeMultipartAPI(size: 10, partSize: 10)
        defer { api.server.stop() }
        let upload = api.upload()
        XCTAssertEqual(try Upload(json: upload.json()), upload)
        XCTAssertEqual(upload.multipart?.partURLTemplate.contains("{part_number}"), true)
        XCTAssertThrowsError(try Upload(json: Data("{}".utf8))) { XCTAssertEqual(($0 as? VidexoError)?.code, .invalidArgument) }
    }

    // MARK: The client

    func testTheClientCreatesAMultipartUploadAndSendsItsParts() async throws {
        let (file, data) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        let created = String(decoding: try api.upload().json(), as: UTF8.self)
        let transport = FakeTransport([ok(created, status: 201)])
        let client = try makeClient(transport)
        let completed = try await client.uploads.upload(file: file, contentType: "video/mp4", multipart: true, partSizeBytes: 100_000)
        XCTAssertEqual(completed.sizeBytes, 200_000)
        XCTAssertEqual(api.joined, data)
        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            #"{"content_type":"video\/mp4","filename":"clip.mp4","multipart":true,"part_size_bytes":100000,"size_bytes":200000}"#
        )
        XCTAssertEqual(transport.paths, ["POST /v1/client/uploads"], "the parts never go through the token's transport")
    }

    func testASmallFileIsASingleUploadUnlessAsked() async throws {
        let transport = FakeTransport([ok(String(decoding: try fixture("upload"), as: UTF8.self), status: 201)])
        let client = try makeClient(transport)
        _ = try await client.uploads.create(forFile: try temporaryFile(10))
        let body = String(decoding: try XCTUnwrap(transport.requests.first?.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("multipart"), body)
    }

    // MARK: The background uploader, on a plain session

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var finished: [(BackgroundUpload, Result<CompletedUpload, VidexoError>)] = []
        private var waiter: CheckedContinuation<(BackgroundUpload, Result<CompletedUpload, VidexoError>), Never>?
        private(set) var progress: [BackgroundUpload] = []

        func add(_ event: BackgroundUploadEvent) {
            lock.lock()
            defer { lock.unlock() }
            switch event {
            case let .progress(upload):
                progress.append(upload)
            case let .finished(upload, result):
                if let waiter {
                    waiter.resume(returning: (upload, result))
                    self.waiter = nil
                } else {
                    finished.append((upload, result))
                }
            }
        }

        func next() async -> (BackgroundUpload, Result<CompletedUpload, VidexoError>) {
            await withCheckedContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if finished.isEmpty {
                    waiter = continuation
                } else {
                    continuation.resume(returning: finished.removeFirst())
                }
            }
        }
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("videxo-test-\(UUID().uuidString)")
    }

    func testTheBackgroundUploaderSendsEachPartAsATaskAndCompletes() async throws {
        let (file, data) = try patternedFile(350_000)
        let api = try FakeMultipartAPI(size: 350_000, partSize: 100_000, received: [2: data[100_000..<200_000]])
        defer { api.server.stop() }
        let events = Events()
        let place = folder()
        let uploader = BackgroundUploader(configuration: .ephemeral, folder: place) { events.add($0) }
        let started = try await uploader.start(file: file, upload: api.upload(), tag: "order-9")
        XCTAssertEqual(started.progress, UploadProgress(loaded: 100_000, total: 350_000))
        let (upload, result) = await events.next()
        XCTAssertEqual(upload.id, started.id)
        XCTAssertEqual(upload.tag, "order-9")
        XCTAssertEqual(try result.get().inputURL, "videxo://uploads/up_1")
        XCTAssertEqual(api.partPuts(2).count, 0)
        XCTAssertEqual(api.calls.filter { $0.hasPrefix("PUT") }.count, 3)
        XCTAssertEqual(events.progress.last?.progress, UploadProgress(loaded: 350_000, total: 350_000))
        XCTAssertEqual(api.calls.last, "POST /v1/uploads/up_1/complete")
        let left = try FileManager.default.contentsOfDirectory(atPath: place.appendingPathComponent("manifests").path)
        XCTAssertEqual(left, [], "nothing of a finished upload stays on the device")
        let afterwards = await uploader.uploads()
        XCTAssertEqual(afterwards, [])
    }

    func testTheBackgroundUploaderEndsOnAPartRefusedWithA4xx() async throws {
        let (file, _) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        api.script(part: 1, [.answer(status: 400, body: problem("invalid_request", status: 400, reason: "checksum_mismatch"))])
        let events = Events()
        let uploader = BackgroundUploader(configuration: .ephemeral, folder: folder(), partsAtOnce: 1) { events.add($0) }
        try await uploader.start(file: file, upload: api.upload())
        let (_, result) = await events.next()
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual(($0 as? VidexoError)?.reason, "checksum_mismatch") }
        XCTAssertEqual(api.partPuts(1).count, 1)
        XCTAssertFalse(api.calls.contains("POST /v1/uploads/up_1/complete"))
    }

    // Not on Linux, where FoundationNetworking itself crashes on a dropped connection (a `try!` in its EasyHandle.swift).
    #if !canImport(FoundationNetworking)
    func testTheBackgroundUploaderSendsAPartAgainAfterALostConnection() async throws {
        let (file, data) = try patternedFile(100_000)
        let api = try FakeMultipartAPI(size: 100_000, partSize: 100_000)
        defer { api.server.stop() }
        api.script(part: 1, [.drop])
        let events = Events()
        let uploader = BackgroundUploader(configuration: .ephemeral, folder: folder()) { events.add($0) }
        try await uploader.start(file: file, upload: api.upload())
        let (_, result) = await events.next()
        XCTAssertNoThrow(try result.get())
        XCTAssertGreaterThanOrEqual(api.partPuts(1).count, 2)
        XCTAssertEqual(api.joined, data)
    }
    #endif

    func testTheBackgroundUploaderGivesUpOnAPartAfterItsRetries() async throws {
        let (file, _) = try patternedFile(100_000)
        let api = try FakeMultipartAPI(size: 100_000, partSize: 100_000)
        defer { api.server.stop() }
        let busy = LocalServer.Reply.answer(status: 503, body: problem("service_unavailable", status: 503, reason: "temporary"))
        api.script(part: 1, Array(repeating: busy, count: 10))
        let events = Events()
        let uploader = BackgroundUploader(configuration: .ephemeral, folder: folder(), maxRetries: 2) { events.add($0) }
        try await uploader.start(file: file, upload: api.upload())
        let (_, result) = await events.next()
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual(($0 as? VidexoError)?.code, .serviceUnavailable) }
        XCTAssertEqual(api.partPuts(1).count, 3)
    }

    func testTheBackgroundUploaderCancelAbortsTheUpload() async throws {
        let (file, _) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        let events = Events()
        let uploader = BackgroundUploader(configuration: .ephemeral, folder: folder()) { events.add($0) }
        let started = try await uploader.start(file: file, upload: api.upload(partsAt: "10.255.255.1:9"))
        let listed = await uploader.uploads()
        XCTAssertEqual(listed.map(\.id), [started.id])
        await uploader.cancel(started.id)
        let (upload, result) = await events.next()
        XCTAssertEqual(upload.id, started.id)
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual(($0 as? VidexoError)?.code, .aborted) }
        XCTAssertTrue(api.deleted)
        let after = await uploader.uploads()
        XCTAssertEqual(after, [])
    }

    func testAnUploadWhoseFileIsGoneAfterARelaunchEndsWithAnError() async throws {
        let (file, _) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        let place = folder()
        let first = BackgroundUploader(configuration: .ephemeral, folder: place) { _ in }
        let started = try await first.start(file: file, upload: api.upload(partsAt: "10.255.255.1:9"))
        try FileManager.default.removeItem(at: file)
        let events = Events()
        let second = BackgroundUploader(configuration: .ephemeral, folder: place) { events.add($0) }
        let (upload, result) = await events.next()
        XCTAssertEqual(upload.id, started.id)
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual(($0 as? VidexoError)?.code, .invalidArgument) }
        withExtendedLifetime(first) {}
        withExtendedLifetime(second) {}
    }

    #if !canImport(FoundationNetworking)
    /// After a background wake the system's completion handler lets the app be suspended: it waits for
    /// the work the events started, here the read of the parts and the completion's task after a relaunch.
    func testTheSystemsCompletionHandlerWaitsForTheQueuedWork() async throws {
        let (file, _) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        let place = folder()
        let first = BackgroundUploader(configuration: .ephemeral, folder: place) { _ in }
        try await first.start(file: file, upload: api.upload(partsAt: "10.255.255.1:9"))
        let reads = api.calls.count
        let events = Events()
        let second = BackgroundUploader(configuration: .ephemeral, folder: place) { events.add($0) }
        let called = expectation(description: "the completion handler")
        let readBefore = LockedFlag()
        second.handleEvents {
            readBefore.set(api.calls.count > reads)
            called.fulfill()
        }
        second.systemFinishedEvents()
        await fulfillment(of: [called], timeout: 10)
        XCTAssertTrue(readBefore.value, "the handler came after the parts were read again")
        withExtendedLifetime(first) {}
    }
    #endif

    /// The session's snapshot of tasks can be taken before a part's end, which is then told before the
    /// restore applies the snapshot: the part arrived and is not under way, whatever the snapshot says.
    func testAPartThatEndsWhileRestoringIsNotTakenAsUnderWay() async throws {
        let (file, _) = try patternedFile(300_000)
        let api = try FakeMultipartAPI(size: 300_000, partSize: 100_000)
        defer { api.server.stop() }
        let place = folder()
        let first = BackgroundUploader(configuration: .ephemeral, folder: place, partsAtOnce: 1) { _ in }
        let started = try await first.start(file: file, upload: api.upload(partsAt: "10.255.255.1:9"))
        let snapshot = SnapshotBox()
        let second = BackgroundUploader(configuration: .ephemeral, folder: place, partsAtOnce: 1, listTasks: { snapshot.apply = $0 }) { _ in }
        let arrived = #"{"part_number":1,"size_bytes":100000,"sha256":"abc"}"#
        second.multipartTaskEnded(id: started.id, part: 1, answer: TaskAnswer(status: 200, headers: [:], body: Data(arrived.utf8), failure: nil))
        // Tasks of the earlier process, as the snapshot lists them: parts 1 and 2, never started, so not ended.
        let other = URLSession(configuration: .ephemeral)
        let tasks = (1...2).map { part -> URLSessionTask in
            let task = other.uploadTask(with: URLRequest(url: URL(string: "http://10.255.255.1:9/")!), fromFile: file)
            task.taskDescription = #"{"id":"\#(started.id)","part":\#(part)}"#
            return task
        }
        try XCTUnwrap(snapshot.apply)(tasks)
        let parts = try XCTUnwrap(second.parts(of: started.id))
        XCTAssertEqual(parts.inFlight, [2])
        XCTAssertEqual(parts.received, [1])
        withExtendedLifetime(first) {}
    }

    /// A process that ends with parts under way: the next one finds the upload in its folder, reads the
    /// received parts and finishes it.
    func testAnUploadOfAnEarlierProcessIsPickedUpAfterARelaunch() async throws {
        let (file, data) = try patternedFile(200_000)
        let api = try FakeMultipartAPI(size: 200_000, partSize: 100_000)
        defer { api.server.stop() }
        let place = folder()
        let first = BackgroundUploader(configuration: .ephemeral, folder: place) { _ in }
        let started = try await first.start(file: file, upload: api.upload(partsAt: "10.255.255.1:9"), tag: "kept")
        // Meanwhile the parts arrived and were joined (here by a foreground send), as when the process ended
        // after the system had sent them: the next process reads the state and only completes.
        _ = try await VidexoUpload().send(file: file, upload: api.upload())
        let events = Events()
        let second = BackgroundUploader(configuration: .ephemeral, folder: place) { events.add($0) }
        let (upload, result) = await events.next()
        XCTAssertEqual(upload.id, started.id)
        XCTAssertEqual(upload.tag, "kept")
        XCTAssertEqual(try result.get().sizeBytes, data.count)
        XCTAssertEqual(api.calls.suffix(2), ["GET /v1/uploads/up_1", "POST /v1/uploads/up_1/complete"])
        withExtendedLifetime(first) {}
        withExtendedLifetime(second) {}
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        flag = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// The restore's handler, held until the test hands it a snapshot of tasks.
final class SnapshotBox: @unchecked Sendable {
    var apply: (([URLSessionTask]) -> Void)?
}
