import XCTest
@testable import Videxo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The PUT through a real URLSession and a real socket on this machine.
final class UploadTests: XCTestCase {
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

    func testSendsTheFileOnceAndAnswersTheCompletedUpload() async throws {
        let server = try LocalServer(reply: .answer(status: 200, body: completedJSON))
        defer { server.stop() }
        let progress = Progress()
        let file = try temporaryFile(300_000)
        let completed = try await VidexoUpload().send(file: file, to: server.url, contentType: "video/mp4") { progress.add($0) }
        XCTAssertEqual(completed.inputURL, "videxo://uploads/up_1")
        XCTAssertEqual(server.requests.count, 1)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(request.requestLine.hasPrefix("PUT /v1/uploads/up_1/content?signature="), request.requestLine)
        XCTAssertEqual(request.headers["content-type"], "video/mp4")
        XCTAssertNil(request.headers["authorization"], "the upload URL needs no credential")
        XCTAssertEqual(request.body.count, 300_000)
        XCTAssertEqual(progress.all.last, UploadProgress(loaded: 300_000, total: 300_000))
        XCTAssertEqual(progress.all.last?.fraction, 1)
    }

    func testARefusedPutBecomesItsProblemAndIsNotRetried() async throws {
        let server = try LocalServer(reply: .answer(status: 409, body: problem("conflict", status: 409, reason: "upload_used")))
        defer { server.stop() }
        await assertThrowsVidexo(.conflict, reason: "upload_used") {
            _ = try await VidexoUpload().send(file: try temporaryFile(10), to: server.url)
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testAnAnswerThatIsNotACompletedUpload() async throws {
        let server = try LocalServer(reply: .answer(status: 200, body: "{}"))
        defer { server.stop() }
        await assertThrowsVidexo(.invalidResponse) {
            _ = try await VidexoUpload().send(file: try temporaryFile(10), to: server.url)
        }
    }

    // Not on Linux, where FoundationNetworking itself crashes on this (a `try!` in its EasyHandle.swift).
    #if !canImport(FoundationNetworking)
    func testALostConnectionIsANetworkErrorWithoutTheUrlAndIsNotRetried() async throws {
        let server = try LocalServer(reply: .dropAfterHeaders)
        defer { server.stop() }
        do {
            _ = try await VidexoUpload().send(file: try temporaryFile(1_000_000), to: server.url)
            XCTFail("Expected an error")
        } catch let error as VidexoError {
            XCTAssertEqual(error.code, .networkError)
            XCTAssertFalse(error.description.contains("signature"), error.description)
        }
        XCTAssertEqual(server.requests.count, 1)
    }
    #endif

    func testRefusesAFileItCannotRead() {
        XCTAssertThrowsError(try VidexoUpload().start(file: URL(fileURLWithPath: "/no/such/file"), to: URL(string: "https://api.test/put")!))
    }

    func testCancellingTheTaskEndsTheUploadWithAborted() async throws {
        let handle = try VidexoUpload().start(file: try temporaryFile(50_000_000), to: URL(string: "http://10.255.255.1:9/never")!)
        handle.cancel()
        await assertThrowsVidexo(.aborted) { _ = try await handle.value }
    }

    // Not on Linux, where FoundationNetworking crashes on a task's `suspend()`.
    #if !canImport(FoundationNetworking)
    func testPauseAndResumeFinishTheUpload() async throws {
        let server = try LocalServer(reply: .answer(status: 200, body: completedJSON))
        defer { server.stop() }
        let handle = try VidexoUpload().start(file: try temporaryFile(1_000_000), to: server.url)
        handle.pause()
        handle.resume()
        let completed = try await handle.value
        XCTAssertEqual(completed.id, "up_1")
        XCTAssertEqual(server.requests.first?.body.count, 1_000_000)
    }
    #endif

    func testTheValueCanBeReadTwice() async throws {
        let server = try LocalServer(reply: .answer(status: 200, body: completedJSON))
        defer { server.stop() }
        let handle = try VidexoUpload().start(file: try temporaryFile(10), to: server.url)
        let first = try await handle.value
        let second = try await handle.value
        XCTAssertEqual(first, second)
    }

    func testTheClientCreatesThenSends() async throws {
        let server = try LocalServer(reply: .answer(status: 200, body: completedJSON))
        defer { server.stop() }
        let created = #"{"id":"up_1","input_url":"videxo://uploads/up_1","upload_url":"\#(server.url.absoluteString)","upload_url_expires_at":"2026-11-06T13:00:00.000Z","expires_at":"2026-11-07T12:00:00.000Z","max_size_bytes":100000000}"#
        let transport = FakeTransport([ok(created, status: 201)])
        let client = try makeClient(transport)
        let progress = Progress()
        let completed = try await client.uploads.upload(file: try temporaryFile(3), contentType: "video/mp4") { progress.add($0) }
        XCTAssertEqual(completed.sizeBytes, 3)
        XCTAssertEqual(server.requests.first?.headers["content-type"], "video/mp4")
        XCTAssertEqual(progress.all.last?.loaded, 3)
        XCTAssertEqual(transport.paths, ["POST /v1/client/uploads"], "the bytes never go through the token's transport")
    }

    // MARK: The background uploader's logic, on a plain session; the system's own part needs an app.

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

    /// URLSession reports no progress at all on some uploads, at random, so this repeats until both
    /// cases have surely come up: the last progress is the file's size in each.
    func testASuccessfulUploadAlwaysEndsWithProgressAtTheFileSize() async throws {
        let size = 200_000
        let server = try LocalServer(reply: .answer(status: 200, body: completedAnswer(sizeBytes: size)))
        defer { server.stop() }
        let file = try temporaryFile(size)
        for attempt in 0..<25 {
            let events = Events()
            let uploader = BackgroundUploader(configuration: .ephemeral) { events.add($0) }
            try uploader.start(file: file, to: server.url, contentType: "video/mp4")
            let (upload, result) = await events.next()
            XCTAssertNoThrow(try result.get(), "attempt \(attempt)")
            let end = UploadProgress(loaded: Int64(size), total: Int64(size))
            XCTAssertEqual(events.progress.last?.progress, end, "attempt \(attempt)")
            XCTAssertEqual(upload.progress, end, "attempt \(attempt)")
        }
        XCTAssertEqual(server.requests.count, 25)
    }

    func testTheBackgroundUploaderTellsProgressAndTheResultWithItsTag() async throws {
        let server = try LocalServer(reply: .answer(status: 200, body: completedAnswer(sizeBytes: 200_000)))
        defer { server.stop() }
        let events = Events()
        let uploader = BackgroundUploader(configuration: .ephemeral) { events.add($0) }
        let started = try uploader.start(file: try temporaryFile(200_000), to: server.url, contentType: "video/mp4", tag: "order-7")
        XCTAssertEqual(started.tag, "order-7")
        XCTAssertEqual(started.progress.total, 200_000)
        let (upload, result) = await events.next()
        XCTAssertEqual(upload.id, started.id)
        XCTAssertEqual(upload.tag, "order-7")
        XCTAssertEqual(try result.get().inputURL, "videxo://uploads/up_1")
        // The last progress comes right before the end, whether or not the system reported any before it.
        XCTAssertEqual(events.progress.last?.progress, UploadProgress(loaded: 200_000, total: 200_000))
        XCTAssertEqual(upload.progress, UploadProgress(loaded: 200_000, total: 200_000))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testTheBackgroundUploaderTellsARefusal() async throws {
        let server = try LocalServer(reply: .answer(status: 410, body: problem("not_found", status: 410, reason: "upload")))
        defer { server.stop() }
        let events = Events()
        let uploader = BackgroundUploader(configuration: .ephemeral) { events.add($0) }
        try uploader.start(file: try temporaryFile(10), to: server.url)
        let (_, result) = await events.next()
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual(($0 as? VidexoError)?.reason, "upload") }
    }

    func testTheBackgroundUploaderListsAndCancels() async throws {
        let events = Events()
        let uploader = BackgroundUploader(configuration: .ephemeral) { events.add($0) }
        let started = try uploader.start(file: try temporaryFile(10_000), to: URL(string: "http://10.255.255.1:9/never")!, tag: "listed")
        let listed = await uploader.uploads()
        XCTAssertEqual(listed.map(\.id), [started.id])
        XCTAssertEqual(listed.first?.tag, "listed")
        #if !canImport(FoundationNetworking)
        await uploader.pause(started.id)
        await uploader.resume(started.id)
        #endif
        await uploader.cancel(started.id)
        let (upload, result) = await events.next()
        XCTAssertEqual(upload.id, started.id)
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual(($0 as? VidexoError)?.code, .aborted) }
        let after = await uploader.uploads()
        XCTAssertEqual(after, [])
    }

    #if os(macOS)
    /// The real background session: the system's daemon sends the file, while this process runs.
    func testARealBackgroundSessionSendsTheFile() async throws {
        let server = try LocalServer(reply: .answer(status: 200, body: completedJSON))
        defer { server.stop() }
        let events = Events()
        let uploader = BackgroundUploader(identifier: "io.videxo.tests.\(UUID().uuidString)") { events.add($0) }
        try uploader.start(file: try temporaryFile(100_000), to: server.url, contentType: "video/mp4", tag: "real")
        let (upload, result) = await events.next()
        XCTAssertEqual(upload.tag, "real")
        XCTAssertEqual(try result.get().id, "up_1")
        XCTAssertEqual(server.requests.first?.body.count, 100_000)
    }
    #endif

    func testTheBackgroundUploaderRefusesAFileItCannotRead() {
        let uploader = BackgroundUploader(configuration: .ephemeral) { _ in }
        XCTAssertThrowsError(try uploader.start(file: URL(fileURLWithPath: "/no/such/file"), to: URL(string: "https://api.test/put")!))
    }
}
