import Foundation

// The answers of the client routes. Only the fields the API documents for a client token: it never
// sees a job's command, inputs, webhook, metadata or usage. A new field in an answer is ignored, and
// a new job state still reads.

/// What `POST /v1/client/uploads` (or your backend's `POST /v1/uploads`) answers: where to send the bytes.
/// It is `Codable`, so an app can keep it to resume a multipart upload after a relaunch; it holds no
/// API key, but its URLs are the upload's capability, so keep it out of logs.
public struct Upload: Codable, Equatable, Sendable {
    public let id: String
    /// `videxo://uploads/<id>`: send this to your backend, which uses it as a job input.
    public let inputURL: String
    /// A single upload's one-time URL, which takes one PUT within one hour. A multipart upload's URL,
    /// read for its received parts and deleted to abort it, for 6 hours.
    public let uploadURL: URL
    /// The end of the write window: one hour for a single upload, 6 hours for a multipart one.
    public let uploadURLExpiresAt: Date
    public let expiresAt: Date
    public let maxSizeBytes: Int
    /// Only on a multipart upload: how to send its parts.
    public let multipart: MultipartPlan?

    enum CodingKeys: String, CodingKey {
        case id
        case inputURL = "input_url"
        case uploadURL = "upload_url"
        case uploadURLExpiresAt = "upload_url_expires_at"
        case expiresAt = "expires_at"
        case maxSizeBytes = "max_size_bytes"
        case multipart
    }

    /// An upload as the API answered it, such as the JSON your backend passes on from `POST /v1/uploads`.
    public init(json: Data) throws {
        do {
            self = try apiDecoder().decode(Upload.self, from: json)
        } catch {
            throw sdkError(.invalidArgument, "The JSON is not an upload as the API answers it.")
        }
    }

    /// The upload as JSON the API's way, which `init(json:)` reads back.
    public func json() throws -> Data {
        try apiEncoder().encode(self)
    }
}

/// How a multipart upload's parts are sent: part `n` is the file's bytes from `(n - 1) * partSizeBytes`,
/// exactly `partSizeBytes` long except the last, which holds the rest.
public struct MultipartPlan: Codable, Equatable, Sendable {
    public let partSizeBytes: Int
    public let partCount: Int
    /// The URL of a part, with `{part_number}` in place of its number. A string, since a URL cannot hold the braces.
    public let partURLTemplate: String
    public let completeURL: URL

    enum CodingKeys: String, CodingKey {
        case partSizeBytes = "part_size_bytes"
        case partCount = "part_count"
        case partURLTemplate = "part_url_template"
        case completeURL = "complete_url"
    }
}

/// One part a multipart upload received.
public struct UploadPart: Decodable, Equatable, Sendable {
    public let partNumber: Int
    public let sizeBytes: Int
    /// SHA-256 of the part as received, hex.
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case sizeBytes = "size_bytes"
        case sha256
    }
}

/// What `GET upload_url` of a multipart upload answers: its state and the parts received, to resume.
public struct MultipartUploadStatus: Decodable, Equatable, Sendable {
    public let id: String
    /// `pending` while parts arrive, `uploading` while a completion runs, then `complete` or `failed`.
    public let state: String
    public let sizeBytes: Int
    public let partSizeBytes: Int
    public let partCount: Int
    /// The parts received, by number. A completed upload lists none: they were joined.
    public let parts: [UploadPart]
    public let inputURL: String
    public let uploadURLExpiresAt: Date
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, state, parts
        case sizeBytes = "size_bytes"
        case partSizeBytes = "part_size_bytes"
        case partCount = "part_count"
        case inputURL = "input_url"
        case uploadURLExpiresAt = "upload_url_expires_at"
        case expiresAt = "expires_at"
    }
}

/// What the upload URL answers once every byte arrived.
public struct CompletedUpload: Decodable, Equatable, Sendable {
    public let id: String
    /// `videxo://uploads/<id>`: send this to your backend, which uses it as a job input.
    public let inputURL: String
    public let sizeBytes: Int
    /// SHA-256 of the file, hex; nil for a multipart upload, whose parts carry their own.
    public let sha256: String?
    public let contentType: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case inputURL = "input_url"
        case sizeBytes = "size_bytes"
        case sha256
        case contentType = "content_type"
        case expiresAt = "expires_at"
    }
}

/// How far an upload has come, in bytes.
public struct UploadProgress: Equatable, Sendable {
    public let loaded: Int64
    public let total: Int64

    public init(loaded: Int64, total: Int64) {
        self.loaded = loaded
        self.total = total
    }

    /// From 0 to 1.
    public var fraction: Double { total > 0 ? min(1, Double(loaded) / Double(total)) : 0 }
}

/// A job's state. `queued` and `running` are active; the others are final. A state this version does
/// not know reads as itself and counts as active.
public struct JobState: RawRepresentable, Hashable, Decodable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let queued = JobState(rawValue: "queued")
    public static let running = JobState(rawValue: "running")
    public static let succeeded = JobState(rawValue: "succeeded")
    public static let failed = JobState(rawValue: "failed")
    public static let cancelled = JobState(rawValue: "cancelled")

    /// Whether the job has ended.
    public var isFinal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

/// Why a job failed.
public struct JobError: Decodable, Equatable, Sendable {
    public let code: String
    /// The documented finer case of `code`, or nil.
    public let reason: String?
    /// What happened, for people; it may change.
    public let message: String
    /// Whether creating the same job again can succeed without a change.
    public let retryable: Bool
    public let logTail: String?

    enum CodingKeys: String, CodingKey {
        case code, reason, message, retryable
        case logTail = "log_tail"
    }
}

/// One output of a job.
public struct ClientJobOutput: Decodable, Equatable, Sendable {
    public let alias: String
    public let filename: String
    public let sizeBytes: Int
    public let contentType: String
    public let expiresAt: Date
    public let deletedAt: Date?
    /// A signed link that needs no token; nil after deletion or retention.
    public let downloadURL: URL?
    public let downloadURLExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case alias, filename
        case sizeBytes = "size_bytes"
        case contentType = "content_type"
        case expiresAt = "expires_at"
        case deletedAt = "deleted_at"
        case downloadURL = "download_url"
        case downloadURLExpiresAt = "download_url_expires_at"
    }
}

/// A job as a client token sees it.
public struct ClientJob: Decodable, Equatable, Sendable {
    public let id: String
    public let state: JobState
    /// From 0 to 1, when known.
    public let progress: Double?
    public let error: JobError?
    public let outputs: [ClientJobOutput]
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, state, progress, error, outputs
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// What `GET /v1/client/token` answers: what the token may still do.
public struct ClientTokenInfo: Decodable, Equatable, Sendable {
    public struct Uploads: Decodable, Equatable, Sendable {
        public let maxCount: Int
        public let maxSizeBytes: Int
        public let contentTypes: [String]
        /// Uploads created over the whole chain.
        public let used: Int

        enum CodingKeys: String, CodingKey {
            case maxCount = "max_count"
            case maxSizeBytes = "max_size_bytes"
            case contentTypes = "content_types"
            case used
        }
    }

    public struct Jobs: Decodable, Equatable, Sendable {
        public let read: [String]
    }

    public let id: String
    public let chainId: String
    public let expiresAt: Date
    public let uploads: Uploads?
    public let jobs: Jobs?

    enum CodingKeys: String, CodingKey {
        case id
        case chainId = "chain_id"
        case expiresAt = "expires_at"
        case uploads, jobs
    }
}

struct ClientJobList: Decodable {
    let data: [ClientJob]
}

private func apiDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

/// The API's encoder: dates as the API writes them.
func apiEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(apiDateFormatter().string(from: date))
    }
    return encoder
}

/// The API's decoder: its dates are ISO 8601, with or without fractions of a second.
func apiDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractions.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date.")
        }
        return date
    }
    return decoder
}
