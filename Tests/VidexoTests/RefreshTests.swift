import XCTest
@testable import Videxo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The refresh flow of a client token: a continuation asked from your backend, with the token's id.
final class RefreshTests: XCTestCase {
    private let jobs = #"{"data":[]}"#

    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String?] = []
        var answers: [Result<FreshToken, Error>]

        init(_ answers: [Result<FreshToken, Error>]) {
            self.answers = answers
        }

        var tokenIds: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return asked
        }

        func getToken(_ request: VidexoClient.TokenRequest) throws -> FreshToken {
            lock.lock()
            defer { lock.unlock() }
            asked.append(request.tokenId)
            return try answers.removeFirst().get()
        }
    }

    private func expired() -> (URLRequest) throws -> FakeTransport.Answer {
        ok(problem("authentication_failed", status: 401, reason: "client_token_expired"), status: 401)
    }

    func testWithoutGetTokenNothingIsReadFirstAndARefusalIsAnswered() async throws {
        let transport = FakeTransport([expired()])
        let client = try makeClient(transport)
        await assertThrowsVidexo(.authenticationFailed, reason: "client_token_expired") { _ = try await client.jobs.list() }
        XCTAssertEqual(transport.paths, ["GET /v1/client/jobs"])
    }

    func testReadsTheTokenBeforeTheFirstCall() async throws {
        let transport = FakeTransport([ok(tokenInfo()), ok(jobs), ok(jobs)])
        let backend = Backend([])
        let client = try makeClient(transport) { try backend.getToken($0) }
        _ = try await client.jobs.list()
        _ = try await client.jobs.list()
        XCTAssertEqual(transport.paths, ["GET /v1/client/token", "GET /v1/client/jobs", "GET /v1/client/jobs"])
        let id = await client.tokenId
        XCTAssertEqual(id, "ct_one")
    }

    func testRefreshesBeforeATokenThatIsAboutToEnd() async throws {
        let transport = FakeTransport([ok(tokenInfo(expiresIn: 10)), ok(jobs)])
        let backend = Backend([.success(FreshToken(token: "vdx_ct_second", id: "ct_two"))])
        let client = try makeClient(transport) { try backend.getToken($0) }
        _ = try await client.jobs.list()
        XCTAssertEqual(backend.tokenIds, ["ct_one"])
        XCTAssertEqual(transport.bearers, [clientToken, "vdx_ct_second"])
        let id = await client.tokenId
        XCTAssertEqual(id, "ct_two")
    }

    func testARefusalAsExpiredOrSupersededRefreshesAndSendsTheCallOnce() async throws {
        for reason in ["client_token_expired", "client_token_superseded"] {
            let refused = ok(problem("authentication_failed", status: 401, reason: reason), status: 401)
            let transport = FakeTransport([ok(tokenInfo()), refused, ok(jobs)])
            let backend = Backend([.success(FreshToken(token: "vdx_ct_second"))])
            let client = try makeClient(transport) { try backend.getToken($0) }
            _ = try await client.jobs.list()
            XCTAssertEqual(transport.bearers, [clientToken, clientToken, "vdx_ct_second"])
            XCTAssertEqual(backend.tokenIds, ["ct_one"])
        }
    }

    func testARevokedTokenIsNotRefreshed() async throws {
        let revoked = ok(problem("authentication_failed", status: 401, reason: "client_token_revoked"), status: 401)
        let transport = FakeTransport([ok(tokenInfo()), revoked])
        let backend = Backend([])
        let client = try makeClient(transport) { try backend.getToken($0) }
        await assertThrowsVidexo(.authenticationFailed, reason: "client_token_revoked") { _ = try await client.jobs.list() }
        XCTAssertEqual(backend.tokenIds, [])
    }

    func testATokenRefusedAtItsFirstReadIsRefreshedWithTheIdItWasGiven() async throws {
        let transport = FakeTransport([expired(), ok(jobs)])
        let backend = Backend([.success(FreshToken(token: "vdx_ct_second", id: "ct_two"))])
        let client = try makeClient(transport, tokenId: "ct_given") { try backend.getToken($0) }
        _ = try await client.jobs.list()
        XCTAssertEqual(backend.tokenIds, ["ct_given"])
        XCTAssertEqual(transport.paths, ["GET /v1/client/token", "GET /v1/client/jobs"])
    }

    func testAFailedRefreshIsAskedAgainWithTheSameId() async throws {
        struct BackendDown: Error {}
        let transport = FakeTransport([ok(tokenInfo()), expired(), expired(), ok(jobs)])
        let backend = Backend([.failure(BackendDown()), .success(FreshToken(token: "vdx_ct_second", id: "ct_two"))])
        let client = try makeClient(transport) { try backend.getToken($0) }
        do {
            _ = try await client.jobs.list()
            XCTFail("Expected the backend's error")
        } catch {
            XCTAssertTrue(error is BackendDown)
        }
        _ = try await client.jobs.list()
        XCTAssertEqual(backend.tokenIds, ["ct_one", "ct_one"])
    }

    func testARefreshAnsweringAnApiKeyIsRefused() async throws {
        let transport = FakeTransport([ok(tokenInfo()), expired()])
        let backend = Backend([.success(FreshToken(token: apiKey))])
        let client = try makeClient(transport) { try backend.getToken($0) }
        await assertThrowsVidexo(.invalidArgument) { _ = try await client.jobs.list() }
        XCTAssertEqual(transport.bearers.filter { $0 == apiKey }, [])
    }

    func testConcurrentCallsShareOneRefresh() async throws {
        let transport = FakeTransport([ok(tokenInfo())])
        let backend = Backend([.success(FreshToken(token: "vdx_ct_second", id: "ct_two"))])
        let client = try makeClient(transport) { request in
            try await Task.sleep(nanoseconds: 30_000_000)
            return try backend.getToken(request)
        }
        _ = try await client.token()
        // Every first send with the old token is refused; every call after the refresh succeeds.
        let count = 5
        for _ in 0..<(count * 2) {
            transport.add { request in
                request.value(forHTTPHeaderField: "Authorization") == "Bearer vdx_ct_second"
                    ? (200, #"{"data":[]}"#, [:])
                    : (401, problem("authentication_failed", status: 401, reason: "client_token_superseded"), [:])
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count { group.addTask { _ = try await client.jobs.list() } }
            try await group.waitForAll()
        }
        XCTAssertEqual(backend.tokenIds, ["ct_one"], "one refresh, and a late refusal mints no third token")
    }

    func testARefreshedTokenThatLooksEndedStopsAskingWhenTheClockRunsAhead() async throws {
        // The device's clock is an hour ahead of the API: every token looks ended.
        let transport = FakeTransport([ok(tokenInfo()), ok(jobs), ok(tokenInfo(id: "ct_two")), ok(jobs)])
        let backend = Backend([.success(FreshToken(token: "vdx_ct_second", id: "ct_two"))])
        let client = try makeClient(transport, clockOffset: 3600) { try backend.getToken($0) }
        _ = try await client.jobs.list()
        _ = try await client.jobs.list()
        XCTAssertEqual(backend.tokenIds, ["ct_one"])
    }

    func testCancellingOneCallLeavesTheSharedRefreshRunning() async throws {
        let transport = FakeTransport([ok(tokenInfo(expiresIn: 10)), ok(tokenInfo(id: "ct_two")), ok(jobs)])
        let backend = Backend([.success(FreshToken(token: "vdx_ct_second", id: "ct_two"))])
        let client = try makeClient(transport) { request in
            try await Task.sleep(nanoseconds: 100_000_000)
            return try backend.getToken(request)
        }
        let cancelled = Task { try await client.jobs.list() }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelled.cancel()
        await assertThrowsVidexo(.aborted) { _ = try await cancelled.value }
        _ = try await client.jobs.list()
        XCTAssertEqual(backend.tokenIds, ["ct_one"])
        XCTAssertEqual(transport.bearers.last, "vdx_ct_second")
    }

    func testFreshTokenDoesNotPrintTheToken() {
        XCTAssertFalse(String(describing: FreshToken(token: "vdx_ct_secret", id: "ct_1")).contains("vdx_ct_secret"))
    }
}
