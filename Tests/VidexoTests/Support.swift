import Foundation
import XCTest
@testable import Videxo
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let clientToken = "vdx_ct_first"
let apiKey = "vdx_" + String(repeating: "a", count: 64)
let base = URL(string: "https://api.test")!

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func tokenInfo(id: String = "ct_one", expiresIn seconds: TimeInterval = 900, now: Date = Date()) -> String {
    let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
    return #"{"id":"\#(id)","chain_id":"ct_one","expires_at":"\#(date)","uploads":null,"jobs":null}"#
}

func problem(_ code: String, status: Int, reason: String? = nil) -> String {
    let reasonField = reason.map { #","reason":"\#($0)""# } ?? ""
    return #"{"type":"https://videxo.io/docs/errors#\#(code)","title":"A title.","status":\#(status),"detail":"A detail.","code":"\#(code)"\#(reasonField),"retryable":false,"request_id":"req_body"}"#
}

/// Answers calls from a script and records them.
final class FakeTransport: VidexoTransport, @unchecked Sendable {
    typealias Answer = (status: Int, body: String, headers: [String: String])
    private let lock = NSLock()
    private var script: [(URLRequest) throws -> Answer]
    private(set) var requests: [URLRequest] = []

    init(_ script: [(URLRequest) throws -> Answer] = []) {
        self.script = script
    }

    func add(_ answer: @escaping (URLRequest) throws -> Answer) {
        lock.lock()
        defer { lock.unlock() }
        script.append(answer)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next = take(request)
        let answer = try next(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        return (Data(answer.body.utf8), response)
    }

    private func take(_ request: URLRequest) -> (URLRequest) throws -> Answer {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !script.isEmpty else { return { _ in throw URLError(.notConnectedToInternet) } }
        return script.removeFirst()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
    }

    var bearers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { String(($0.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer ".count)) }
    }
}

func ok(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> (URLRequest) throws -> FakeTransport.Answer {
    { _ in (status, body, headers) }
}

/// Records the waits; the tests never sleep for a backoff.
final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    func add(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(seconds)
    }

    var all: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

func environment(sleeps: Sleeps = Sleeps(), now: @escaping @Sendable () -> Date = { Date() }) -> SDKEnvironment {
    var environment = SDKEnvironment()
    environment.sleep = { seconds in
        sleeps.add(seconds)
        try Task.checkCancellation()
    }
    environment.random = { 1 }
    environment.now = now
    environment.uuid = { "key-1" }
    return environment
}

func makeClient(
    _ transport: FakeTransport,
    tokenId: String? = nil,
    token: String = clientToken,
    sleeps: Sleeps = Sleeps(),
    clockOffset: TimeInterval = 0,
    timeout: TimeInterval? = 60,
    getToken: VidexoClient.GetToken? = nil
) throws -> VidexoClient {
    try VidexoClient(
        token: token,
        tokenId: tokenId,
        baseURL: base,
        transport: transport,
        maxRetries: 2,
        timeout: timeout,
        environment: environment(sleeps: sleeps, now: { Date().addingTimeInterval(clockOffset) }),
        getToken: getToken
    )
}

func assertThrowsVidexo(
    _ code: VidexoError.Code,
    reason: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("Expected \(code)", file: file, line: line)
    } catch let error as VidexoError {
        XCTAssertEqual(error.code, code, "\(error)", file: file, line: line)
        if let reason { XCTAssertEqual(error.reason, reason, file: file, line: line) }
    } catch {
        XCTFail("Expected a VidexoError, got \(error)", file: file, line: line)
    }
}

func temporaryFile(_ bytes: Int, name: String = "clip.mp4") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(name)
    try Data(repeating: 7, count: bytes).write(to: file)
    return file
}

/// A real HTTP server on a local port, so uploads go through URLSession itself: it reads one request a
/// connection and answers what the test says, or drops the connection.
final class LocalServer: @unchecked Sendable {
    struct Received {
        let requestLine: String
        let headers: [String: String]
        let body: Data
    }

    enum Reply {
        case answer(status: Int, body: String)
        case dropAfterHeaders
    }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private let reply: Reply
    private var received: [Received] = []

    init(reply: Reply) throws {
        self.reply = reply
        #if canImport(Glibc)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(descriptor, 8), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/v1/uploads/up_1/content?signature=secret-signature")! }

    var requests: [Received] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    private func serve() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 { return }
            Thread.detachNewThread { [self] in handle(connection) }
        }
    }

    private func handle(_ connection: Int32) {
        defer { close(connection) }
        var buffer = Data()
        let size = 65_536
        var chunk = [UInt8](repeating: 0, count: size)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = recv(connection, &chunk, size, 0)
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            headerEnd = buffer.range(of: separator)
        }
        let lines = String(decoding: buffer[..<headerEnd!.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["expect"] != nil { _ = "HTTP/1.1 100 Continue\r\n\r\n".withCString { send(connection, $0, strlen($0), 0) } }
        if case .dropAfterHeaders = reply {
            record(Received(requestLine: lines[0], headers: headers, body: Data()))
            return
        }
        var body = Data(buffer[headerEnd!.upperBound...])
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < expected {
            let count = recv(connection, &chunk, size, 0)
            if count <= 0 { return }
            body.append(contentsOf: chunk[0..<count])
        }
        record(Received(requestLine: lines[0], headers: headers, body: body))
        if case let .answer(status, text) = reply {
            let answer = "HTTP/1.1 \(status) Answer\r\nContent-Type: application/json\r\nRequest-Id: req_header\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"
            _ = answer.withCString { send(connection, $0, strlen($0), 0) }
        }
    }

    private func record(_ request: Received) {
        lock.lock()
        defer { lock.unlock() }
        received.append(request)
    }
}

/// What the upload URL answers for a file of this size. The API answers the exact byte length it received.
func completedAnswer(sizeBytes: Int) -> String {
    #"{"id":"up_1","input_url":"videxo://uploads/up_1","size_bytes":\#(sizeBytes),"sha256":"abc","content_type":"video/mp4","expires_at":"2026-11-07T12:00:00.000Z"}"#
}

let completedJSON = completedAnswer(sizeBytes: 3)
