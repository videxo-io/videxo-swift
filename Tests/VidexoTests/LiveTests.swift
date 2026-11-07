import XCTest
@testable import Videxo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The whole flow against a real API: runs only when `VIDEXO_LIVE_API_URL` and `VIDEXO_LIVE_API_KEY`
/// name one. The key plays the backend here, as it never does in an app.
final class LiveTests: XCTestCase {
    private func backend(_ path: String, _ body: [String: Any], url: URL, key: String) async throws -> [String: Any] {
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSessionTransport().send(request)
        XCTAssertTrue((200..<300).contains(response.statusCode), String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testARefreshOfATokenThatOnlyUploads() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["VIDEXO_LIVE_API_URL"], let key = environment["VIDEXO_LIVE_API_KEY"], let url = URL(string: address) else {
            throw XCTSkip("Set VIDEXO_LIVE_API_URL and VIDEXO_LIVE_API_KEY to run against an API.")
        }
        let grant: [String: Any] = ["max_count": 1, "max_size_bytes": 1000, "content_types": ["video/*"]]
        let minted = try await backend("v1/client-tokens", ["subject": "user_swift_upload", "uploads": grant], url: url, key: key)
        let first = try XCTUnwrap(minted["token"] as? String)
        let firstId = try XCTUnwrap(minted["id"] as? String)

        // A newer token's first use ends the first one, so the app's next call needs a refresh.
        let newer = try await backend("v1/client-tokens", ["continues": firstId, "uploads": grant], url: url, key: key)
        _ = try await VidexoClient(token: try XCTUnwrap(newer["token"] as? String), baseURL: url).token()

        let asked = LockedList()
        let app = try VidexoClient(token: first, tokenId: firstId, baseURL: url) { [self] request in
            asked.add(1)
            let next = try await backend("v1/client-tokens", ["continues": request.tokenId ?? firstId, "uploads": grant], url: url, key: key)
            return FreshToken(token: try XCTUnwrap(next["token"] as? String), id: next["id"] as? String)
        }
        let upload = try await app.uploads.create(filename: "talk.mp4", sizeBytes: 3, contentType: "video/mp4")
        XCTAssertEqual(upload.inputURL, "videxo://uploads/\(upload.id)")
        XCTAssertEqual(asked.count, 1)
        let info = try await app.token()
        XCTAssertEqual(info.chainId, firstId)
        XCTAssertEqual(info.uploads?.used, 1, "a refresh never resets the count")
    }

    func testAnAppUploadsAndFollowsAJobWithAClientToken() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["VIDEXO_LIVE_API_URL"], let key = environment["VIDEXO_LIVE_API_KEY"], let url = URL(string: address) else {
            throw XCTSkip("Set VIDEXO_LIVE_API_URL and VIDEXO_LIVE_API_KEY to run against an API.")
        }

        // The backend mints an upload token; the app holds only that.
        let minted = try await backend(
            "v1/client-tokens",
            ["subject": "user_swift", "uploads": ["max_count": 1, "max_size_bytes": 300_000, "content_types": ["video/*"]]],
            url: url,
            key: key
        )
        let first = try XCTUnwrap(minted["token"] as? String)
        let firstId = try XCTUnwrap(minted["id"] as? String)
        let app = try VidexoClient(token: first, baseURL: url)

        let info = try await app.token()
        XCTAssertEqual(info.id, firstId)
        XCTAssertEqual(info.uploads?.used, 0)

        // A file the grant does not allow is refused before it counts.
        await assertThrowsVidexo(.invalidRequest) {
            _ = try await app.uploads.create(filename: "big.mp4", sizeBytes: 300_001, contentType: "video/mp4")
        }

        // A real PUT, with progress, the same as an app's. A background session needs an app to run in.
        let progress = LockedList()
        let file = try temporaryFile(200_000, name: "talk.mp4")
        let completed = try await app.uploads.upload(file: file, contentType: "video/mp4") { progress.add($0.loaded) }
        XCTAssertEqual(completed.inputURL, "videxo://uploads/\(completed.id)")
        XCTAssertEqual(completed.sizeBytes, 200_000)
        XCTAssertEqual(progress.last, 200_000)

        // The count is spent, over the chain.
        await assertThrowsVidexo(.limitExceeded, reason: "token_uploads") {
            _ = try await app.uploads.create(filename: "two.mp4", sizeBytes: 3, contentType: "video/mp4")
        }

        // The upload URL takes one PUT.
        let second = try await backend("v1/uploads", ["filename": "again.mp4", "size_bytes": 3, "content_type": "video/mp4"], url: url, key: key)
        let again = try XCTUnwrap(URL(string: try XCTUnwrap(second["upload_url"] as? String)))
        let short = try temporaryFile(3, name: "again.mp4")
        _ = try await VidexoUpload().send(file: short, to: again, contentType: "video/mp4")
        await assertThrowsVidexo(.conflict) { _ = try await VidexoUpload().send(file: short, to: again, contentType: "video/mp4") }

        // A token has no way to a job it was not given.
        await assertThrowsVidexo(.permissionDenied, reason: "token_scope") { _ = try await app.jobs.get("job_000000000000000000000000") }

        // Only the backend creates the job, and answers a continuation that adds it.
        let job = try await backend("v1/transcode", ["input": completed.inputURL, "preset": "web-720p"], url: url, key: key)
        let jobId = try XCTUnwrap(job["id"] as? String)
        let following = try await backend("v1/client-tokens", ["continues": firstId, "jobs": ["read": [jobId]]], url: url, key: key)
        let followerToken = try XCTUnwrap(following["token"] as? String)
        let refreshed = LockedList()
        let follower = try VidexoClient(token: followerToken, tokenId: following["id"] as? String, baseURL: url) { [self] request in
            refreshed.add(1)
            let next = try await backend("v1/client-tokens", ["continues": request.tokenId ?? firstId], url: url, key: key)
            return FreshToken(token: try XCTUnwrap(next["token"] as? String), id: next["id"] as? String)
        }

        let ended = try await follower.jobs.wait(jobId, timeout: 120, interval: 0.5)
        XCTAssertTrue(ended.state.isFinal)
        let listed = try await follower.jobs.list()
        XCTAssertEqual(listed.map(\.id), [jobId])
        let chain = try await follower.token()
        XCTAssertEqual(chain.chainId, firstId)
        XCTAssertEqual(chain.jobs?.read, [jobId])

        // The newer token's first use ended the older one.
        await assertThrowsVidexo(.authenticationFailed, reason: "client_token_superseded") { _ = try await app.token() }

        // The first token now answers superseded, so a client still on it refreshes through `getToken`.
        let backOnTheFirst = try VidexoClient(token: first, tokenId: firstId, baseURL: url) { [self] request in
            refreshed.add(1)
            let next = try await backend("v1/client-tokens", ["continues": request.tokenId ?? firstId], url: url, key: key)
            return FreshToken(token: try XCTUnwrap(next["token"] as? String), id: next["id"] as? String)
        }
        _ = try await backOnTheFirst.token()
        XCTAssertEqual(refreshed.count, 1)

        // An API key stops at the SDK.
        XCTAssertThrowsError(try VidexoClient(token: key, baseURL: url))
    }
}

private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func add(_ value: Int64) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var last: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
}
