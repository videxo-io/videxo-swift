import Foundation

/// One field that failed in an `invalid_request` answer: `detail` and one of the other three.
public struct FieldError: Decodable, Equatable, Sendable {
    public let detail: String
    /// A JSON Pointer into the body, such as `#/size_bytes`.
    public let pointer: String?
    public let parameter: String?
    public let header: String?
}

/// Every failure of a call: a problem details answer of the API, or one of the SDK's own codes with
/// `status` nil. Programs branch on `code`, and on `reason` for the finer case. The text of this
/// error never holds a token or an upload URL.
public struct VidexoError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// An error code. It is open, since the API may add codes.
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public var description: String { rawValue }

        // What the client routes and the upload URL answer (the Errors page lists every code).
        public static let invalidRequest = Code(rawValue: "invalid_request")
        public static let authenticationFailed = Code(rawValue: "authentication_failed")
        public static let permissionDenied = Code(rawValue: "permission_denied")
        public static let notFound = Code(rawValue: "not_found")
        public static let conflict = Code(rawValue: "conflict")
        public static let resourceExpired = Code(rawValue: "resource_expired")
        public static let limitExceeded = Code(rawValue: "limit_exceeded")
        public static let rateLimited = Code(rawValue: "rate_limited")
        public static let internalError = Code(rawValue: "internal_error")
        public static let serviceUnavailable = Code(rawValue: "service_unavailable")

        // The SDK's own: there is no problem details answer to read.
        /// The request did not get an answer (DNS, TLS, a reset connection).
        public static let networkError = Code(rawValue: "network_error")
        /// No answer within the timeout.
        public static let timeout = Code(rawValue: "timeout")
        /// The calling task was cancelled, or the upload was.
        public static let aborted = Code(rawValue: "aborted")
        /// `jobs.wait` gave up before the job ended.
        public static let waitTimeout = Code(rawValue: "wait_timeout")
        /// An error answer that is not problem details (a proxy's HTML page, for example).
        public static let httpError = Code(rawValue: "http_error")
        /// A successful answer the SDK could not read.
        public static let invalidResponse = Code(rawValue: "invalid_response")
        /// A value the SDK refuses before sending anything: an API key, a file it cannot read.
        public static let invalidArgument = Code(rawValue: "invalid_argument")
    }

    /// The HTTP status; nil when no answer came.
    public let status: Int?
    public let code: Code
    /// The code's fixed sentence.
    public let title: String
    /// What happened this time, for people; it may change.
    public let detail: String
    /// `https://videxo.io/docs/errors#<code>` for an API error; nil otherwise.
    public let type: String?
    /// With `invalid_request`: one entry per field that failed.
    public let errors: [FieldError]
    /// The documented finer case of `code`; nil without one.
    public let reason: String?
    /// The API's hint whether the same request can succeed later; nil for the SDK's own codes.
    public let retryable: Bool?
    /// The answer's request id; quote it to support. Nil when no answer came.
    public let requestId: String?
    /// Seconds from the answer's `Retry-After` header (429, 503); nil without one.
    public let retryAfter: Int?
    /// The answer's body as received; nil when no answer came.
    public let body: Data?

    init(
        status: Int?,
        code: Code,
        title: String,
        detail: String,
        type: String? = nil,
        errors: [FieldError] = [],
        reason: String? = nil,
        retryable: Bool? = nil,
        requestId: String? = nil,
        retryAfter: Int? = nil,
        body: Data? = nil
    ) {
        self.status = status
        self.code = code
        self.title = title
        self.detail = detail
        self.type = type
        self.errors = errors
        self.reason = reason
        self.retryable = retryable
        self.requestId = requestId
        self.retryAfter = retryAfter
        self.body = body
    }

    public var description: String {
        "\(code.rawValue)\(status.map { " (\($0))" } ?? ""): \(detail)"
    }

    public var errorDescription: String? { description }
}

private let sdkTitles: [VidexoError.Code: String] = [
    .networkError: "The request did not get an answer.",
    .timeout: "The request timed out.",
    .aborted: "The request was aborted.",
    .waitTimeout: "The job did not end within the wait.",
    .httpError: "The API answered with an error that is not problem details.",
    .invalidResponse: "The API answered with a body the SDK could not read.",
    .invalidArgument: "The SDK refused a value before sending anything.",
]

/// An error with one of the SDK's own codes.
func sdkError(
    _ code: VidexoError.Code,
    _ detail: String,
    status: Int? = nil,
    requestId: String? = nil,
    retryAfter: Int? = nil,
    body: Data? = nil
) -> VidexoError {
    VidexoError(
        status: status,
        code: code,
        title: sdkTitles[code] ?? detail,
        detail: detail,
        requestId: requestId,
        retryAfter: retryAfter,
        body: body
    )
}

private let httpDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

/// Seconds of a `Retry-After` header, as a number of seconds or an HTTP date; nil when absent or unreadable.
func retryAfterSeconds(_ value: String?, now: Date = Date()) -> Int? {
    guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    if text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) { return Int(text) }
    guard let date = httpDate.date(from: text) else { return nil }
    return max(0, Int(date.timeIntervalSince(now).rounded(.up)))
}

private struct ProblemBody: Decodable {
    let code: String
    let title: String
    let detail: String?
    let type: String?
    let errors: [FieldError]?
    let reason: String?
    let retryable: Bool?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case code, title, detail, type, errors, reason, retryable
        case requestId = "request_id"
    }
}

/// The error of a non-2xx answer.
func errorFromResponse(status: Int, headers: HTTPHeaders, body: Data) -> VidexoError {
    let retryAfter = retryAfterSeconds(headers["retry-after"])
    let headerId = headers["request-id"]
    guard let problem = try? JSONDecoder().decode(ProblemBody.self, from: body) else {
        return sdkError(.httpError, "The API answered \(status).", status: status, requestId: headerId, retryAfter: retryAfter, body: body)
    }
    return VidexoError(
        status: status,
        code: VidexoError.Code(rawValue: problem.code),
        title: problem.title,
        detail: problem.detail ?? problem.title,
        type: problem.type,
        errors: problem.errors ?? [],
        reason: problem.reason,
        retryable: problem.retryable,
        requestId: problem.requestId ?? headerId,
        retryAfter: retryAfter,
        body: body
    )
}
