import XCTest
@testable import Videxo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ClientTests: XCTestCase {
    // MARK: What the constructor refuses

    func testRefusesAnApiKeyWithoutRepeatingIt() {
        XCTAssertThrowsError(try makeClient(FakeTransport(), token: apiKey)) { error in
            let error = error as? VidexoError
            XCTAssertEqual(error?.code, .invalidArgument)
            XCTAssertFalse(error?.description.contains(apiKey) ?? true)
            XCTAssertTrue(error?.detail.contains("never an API key") ?? false)
        }
    }

    func testRefusesAnythingButAClientToken() {
        for value in ["", "vdx_short", "vdx_ct_with space", "vdx_ct_é", "Bearer vdx_ct_x"] {
            XCTAssertThrowsError(try makeClient(FakeTransport(), token: value), value)
        }
        XCTAssertNoThrow(try makeClient(FakeTransport(), token: "  vdx_ct_ok\n"))
    }

    func testRefusesABaseUrlThatIsNotHttp() {
        XCTAssertThrowsError(
            try VidexoClient(token: clientToken, baseURL: URL(string: "ftp://api.test")!)
        )
    }

    func testBaseUrlLosesItsTrailingSlash() async throws {
        let transport = FakeTransport([ok(#"{"data":[]}"#)])
        let client = try VidexoClient(token: clientToken, baseURL: URL(string: "https://api.test///")!, transport: transport)
        _ = try await client.jobs.list()
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.test/v1/client/jobs")
    }

    // MARK: Requests and models

    func testCreateSendsTheBodyAndAnIdempotencyKey() async throws {
        let transport = FakeTransport([ok(String(decoding: try fixture("upload"), as: UTF8.self), status: 201)])
        let client = try makeClient(transport)
        let upload = try await client.uploads.create(filename: "clip.mp4", sizeBytes: 3, contentType: "video/mp4")
        XCTAssertEqual(upload.inputURL, "videxo://uploads/up_0123456789abcdef01234567")
        XCTAssertEqual(upload.maxSizeBytes, 100_000_000)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.paths, ["POST /v1/client/uploads"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(clientToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "key-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self), #"{"content_type":"video\/mp4","filename":"clip.mp4","size_bytes":3}"#)
    }

    func testCreateForAFileReadsItsSizeAndMakesAPlainName() async throws {
        let transport = FakeTransport([ok(String(decoding: try fixture("upload"), as: UTF8.self), status: 201)])
        let client = try makeClient(transport)
        let file = try temporaryFile(5, name: "_my clip é.mp4")
        _ = try await client.uploads.create(forFile: file, contentType: "video/mp4", idempotencyKey: "mine")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "mine")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["filename"] as? String, "my-clip--.mp4")
        XCTAssertEqual(body["size_bytes"] as? Int, 5)
    }

    func testCreateForAFileRefusesOneItCannotRead() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport)
        await assertThrowsVidexo(.invalidArgument) {
            _ = try await client.uploads.create(forFile: URL(fileURLWithPath: "/no/such/file.mp4"))
        }
        await assertThrowsVidexo(.invalidArgument) {
            _ = try await client.uploads.create(forFile: URL(string: "https://example.com/a.mp4")!)
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testPlainFilename() {
        XCTAssertEqual(plainFilename("clip.mp4"), "clip.mp4")
        XCTAssertEqual(plainFilename("..."), "upload.bin")
        XCTAssertEqual(plainFilename("---a b.mov"), "a-b.mov")
        let long = plainFilename(String(repeating: "x", count: 200) + ".mp4")
        XCTAssertEqual(long.count, 105)
        XCTAssertTrue(long.hasSuffix(".mp4"))
    }

    func testReadsAClientJob() async throws {
        let transport = FakeTransport([ok(String(decoding: try fixture("client-job"), as: UTF8.self))])
        let client = try makeClient(transport)
        let job = try await client.jobs.get("job_3k9x0c2mfq8w1n7r5t4b6v2z")
        XCTAssertEqual(transport.paths, ["GET /v1/client/jobs/job_3k9x0c2mfq8w1n7r5t4b6v2z"])
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.state.isFinal)
        XCTAssertEqual(job.progress, 0.5)
        XCTAssertEqual(job.error?.reason, "ffmpeg_error")
        XCTAssertEqual(job.error?.logTail, "Invalid data found when processing input")
        XCTAssertEqual(job.outputs.first?.downloadURL?.lastPathComponent, "web.mp4")
        XCTAssertNil(job.outputs.last?.downloadURL)
        XCTAssertNotNil(job.outputs.last?.deletedAt)
        XCTAssertNotNil(job.finishedAt, "a date without fractions of a second reads too")
    }

    func testAnIdOutsideThePathIsEncoded() async throws {
        let transport = FakeTransport([ok(problem("not_found", status: 404, reason: "job"), status: 404)])
        let client = try makeClient(transport)
        await assertThrowsVidexo(.notFound, reason: "job") { _ = try await client.jobs.get("../keys") }
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.test/v1/client/jobs/..%2Fkeys")
    }

    func testAJobInAnUnknownStateStillReads() async throws {
        var job = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture("client-job")) as? [String: Any])
        job["state"] = "paused"
        job["new_field"] = true
        let data = try JSONSerialization.data(withJSONObject: job)
        let read = try apiDecoder().decode(ClientJob.self, from: data)
        XCTAssertEqual(read.state.rawValue, "paused")
        XCTAssertFalse(read.state.isFinal)
    }

    func testReadsTheTokenAndRemembersItsId() async throws {
        let transport = FakeTransport([ok(String(decoding: try fixture("client-token-info"), as: UTF8.self))])
        let client = try makeClient(transport)
        let info = try await client.token()
        XCTAssertEqual(info.uploads?.maxCount, 1)
        XCTAssertEqual(info.jobs?.read, ["job_3k9x0c2mfq8w1n7r5t4b6v2z"])
        let id = await client.tokenId
        XCTAssertEqual(id, "ct_4m8x2k9q0c3v7n1r5t6b2z8w")
    }

    func testListAnswersTheJobs() async throws {
        let job = String(decoding: try fixture("client-job"), as: UTF8.self)
        let client = try makeClient(FakeTransport([ok(#"{"data":[\#(job)]}"#)]))
        let jobs = try await client.jobs.list()
        XCTAssertEqual(jobs.map(\.id), ["job_3k9x0c2mfq8w1n7r5t4b6v2z"])
    }

    // MARK: Errors

    func testAProblemBecomesAVidexoError() async throws {
        let body = ##"{"type":"https://videxo.io/docs/errors#invalid_request","title":"Not valid.","status":400,"detail":"Too large.","code":"invalid_request","reason":"invalid_fields","retryable":false,"request_id":"req_1","errors":[{"detail":"Too big.","pointer":"#/size_bytes"}]}"##
        let client = try makeClient(FakeTransport([ok(body, status: 400)]))
        do {
            _ = try await client.uploads.create(filename: "a.mp4", sizeBytes: 3)
            XCTFail("Expected an error")
        } catch let error as VidexoError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.reason, "invalid_fields")
            XCTAssertEqual(error.title, "Not valid.")
            XCTAssertEqual(error.detail, "Too large.")
            XCTAssertEqual(error.type, "https://videxo.io/docs/errors#invalid_request")
            XCTAssertEqual(error.requestId, "req_1")
            XCTAssertEqual(error.retryable, false)
            XCTAssertEqual(error.errors.first?.pointer, "#/size_bytes")
            XCTAssertEqual(error.errorDescription, "invalid_request (400): Too large.")
            XCTAssertNotNil(error.body)
        }
    }

    func testAnErrorThatIsNotProblemDetails() async throws {
        let client = try makeClient(FakeTransport([ok("<html>", status: 500, headers: ["Request-Id": "req_h"])]))
        do {
            _ = try await client.jobs.list()
            XCTFail("Expected an error")
        } catch let error as VidexoError {
            XCTAssertEqual(error.code, .httpError)
            XCTAssertEqual(error.status, 500)
            XCTAssertEqual(error.requestId, "req_h")
        }
    }

    func testASuccessTheSdkCannotRead() async throws {
        let client = try makeClient(FakeTransport([ok("not json")]))
        await assertThrowsVidexo(.invalidResponse) { _ = try await client.jobs.list() }
    }

    func testRetryAfterReadsSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(retryAfterSeconds("7"), 7)
        XCTAssertNil(retryAfterSeconds(nil))
        XCTAssertNil(retryAfterSeconds(" "))
        XCTAssertNil(retryAfterSeconds("soon"))
        XCTAssertEqual(retryAfterSeconds("Mon, 12 Jan 1970 13:46:50 GMT", now: now), 10)
        XCTAssertEqual(retryAfterSeconds("Mon, 12 Jan 1970 13:46:30 GMT", now: now), 0)
    }

    // MARK: Retries

    func testRetriesWithBackoffAndTheSameIdempotencyKey() async throws {
        let sleeps = Sleeps()
        let transport = FakeTransport([ok("", status: 503), ok("", status: 502), ok(String(decoding: try fixture("upload"), as: UTF8.self), status: 201)])
        let client = try makeClient(transport, sleeps: sleeps)
        _ = try await client.uploads.create(filename: "a.mp4", sizeBytes: 3)
        XCTAssertEqual(sleeps.all, [0.5, 1])
        XCTAssertEqual(Set(transport.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["key-1"])
    }

    func testHonoursRetryAfterAndStopsAtTheLimit() async throws {
        let sleeps = Sleeps()
        let limited = problem("rate_limited", status: 429)
        let transport = FakeTransport(Array(repeating: ok(limited, status: 429, headers: ["Retry-After": "7"]), count: 3))
        let client = try makeClient(transport, sleeps: sleeps)
        await assertThrowsVidexo(.rateLimited) { _ = try await client.jobs.list() }
        XCTAssertEqual(sleeps.all, [7, 7])
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testAnswersARetryAfterPastTheLimitWithoutWaiting() async throws {
        let sleeps = Sleeps()
        let transport = FakeTransport([ok(problem("rate_limited", status: 429), status: 429, headers: ["Retry-After": "61"])])
        let client = try makeClient(transport, sleeps: sleeps)
        do {
            _ = try await client.jobs.list()
            XCTFail("Expected an error")
        } catch let error as VidexoError {
            XCTAssertEqual(error.retryAfter, 61)
        }
        XCTAssertEqual(sleeps.all, [])
    }

    func testDoesNotRetryOtherStatuses() async throws {
        let transport = FakeTransport([ok(problem("internal_error", status: 500), status: 500), ok("{}")])
        let client = try makeClient(transport)
        await assertThrowsVidexo(.internalError) { _ = try await client.jobs.list() }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRetriesANetworkErrorThenAnswersIt() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport)
        await assertThrowsVidexo(.networkError) { _ = try await client.jobs.list() }
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testANetworkErrorNeverHoldsTheToken() async throws {
        struct Leaky: LocalizedError {
            var errorDescription: String? { "failed with Bearer \(clientToken)" }
        }
        let leak: (URLRequest) throws -> FakeTransport.Answer = { _ in throw Leaky() }
        let client = try makeClient(FakeTransport(Array(repeating: leak, count: 3)))
        do {
            _ = try await client.jobs.list()
            XCTFail("Expected an error")
        } catch let error as VidexoError {
            XCTAssertEqual(error.code, .networkError)
            XCTAssertFalse(error.description.contains(clientToken), error.description)
            XCTAssertTrue(error.description.contains("[client token]"), error.description)
        }
    }

    func testAnAttemptThatTakesTooLongIsATimeout() async throws {
        struct Slow: VidexoTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw URLError(.unknown)
            }
        }
        let client = try VidexoClient(
            token: clientToken,
            tokenId: nil,
            baseURL: base,
            transport: Slow(),
            maxRetries: 0,
            timeout: 0.05,
            environment: environment(),
            getToken: nil
        )
        await assertThrowsVidexo(.timeout) { _ = try await client.jobs.list() }
    }

    func testCancellingTheTaskAbortsTheCall() async throws {
        struct Forever: VidexoTransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw URLError(.unknown)
            }
        }
        let client = try VidexoClient(token: clientToken, baseURL: base, transport: Forever())
        let call = Task { try await client.jobs.list() }
        try await Task.sleep(nanoseconds: 50_000_000)
        call.cancel()
        await assertThrowsVidexo(.aborted) { _ = try await call.value }
    }

    // MARK: Waiting

    func testWaitReadsUntilTheJobEndsAndAnswersAFailedJob() async throws {
        let sleeps = Sleeps()
        let failed = String(decoding: try fixture("client-job"), as: UTF8.self)
        let running = failed.replacingOccurrences(of: #""state": "failed""#, with: #""state": "running""#)
        let limited = problem("rate_limited", status: 429)
        let transport = FakeTransport([
            ok(running),
            ok(limited, status: 429, headers: ["Retry-After": "61"]),
            ok(failed),
        ])
        let client = try makeClient(transport, sleeps: sleeps)
        let job = try await client.jobs.wait("job_1", timeout: 30, interval: 2)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(sleeps.all, [2, 61], "a 429 is waited out by its Retry-After")
    }

    func testWaitGivesUpAtItsTimeout() async throws {
        let running = String(decoding: try fixture("client-job"), as: UTF8.self)
            .replacingOccurrences(of: #""state": "failed""#, with: #""state": "running""#)
        let transport = FakeTransport(Array(repeating: ok(running), count: 10_000))
        var slow = environment()
        slow.sleep = { _ in try await Task.sleep(nanoseconds: 5_000_000) }
        let client = try VidexoClient(token: clientToken, tokenId: nil, baseURL: base, transport: transport, maxRetries: 0, timeout: 5, environment: slow, getToken: nil)
        await assertThrowsVidexo(.waitTimeout) { _ = try await client.jobs.wait("job_1", timeout: 0.05, interval: 0.001) }
    }

    func testWaitPassesOtherErrorsOn() async throws {
        let client = try makeClient(FakeTransport([ok(problem("not_found", status: 404, reason: "job"), status: 404)]))
        await assertThrowsVidexo(.notFound, reason: "job") { _ = try await client.jobs.wait("job_1") }
    }

    func testCancellingAWaitAborts() async throws {
        let running = String(decoding: try fixture("client-job"), as: UTF8.self)
            .replacingOccurrences(of: #""state": "failed""#, with: #""state": "running""#)
        let transport = FakeTransport(Array(repeating: ok(running), count: 10_000))
        var slow = environment()
        slow.sleep = { _ in try await Task.sleep(nanoseconds: 5_000_000) }
        let client = try VidexoClient(token: clientToken, tokenId: nil, baseURL: base, transport: transport, maxRetries: 0, timeout: 5, environment: slow, getToken: nil)
        let wait = Task { try await client.jobs.wait("job_1", timeout: 30, interval: 0.001) }
        try await Task.sleep(nanoseconds: 30_000_000)
        wait.cancel()
        await assertThrowsVidexo(.aborted) { _ = try await wait.value }
    }
}
